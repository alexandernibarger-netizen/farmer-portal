-- Refund rule change (Alex, 2026-10-07): the quotas are effort only (steps 0-4 plus the activity and quiz rules),
-- and the refund is $500 minus the referral fees earned on jobs closed by day 90. No refund once those fees reach $500.
create or replace function public.refund_progress(p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f uuid := coalesce(p_farmer, auth.uid());
  p public.profiles;
  t0 timestamptz;
  d int;
  steps jsonb := '[]';
  v1 int; v2 int; v3 int; ok boolean;
  fees numeric := 0;
begin
  if f <> auth.uid() and not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into p from public.profiles where id = f;
  if p.id is null or not p.enrollment_paid or p.enrolled_at is null then return jsonb_build_object('enrolled', false); end if;
  t0 := p.enrolled_at;
  d := floor(extract(epoch from now() - t0) / 86400)::int;

  -- 0: 15 business models approved by day 3
  ok := p.niche_approved_at is not null and p.niche_submitted_at <= t0 + interval '3 days';  -- sent in time; review may land later
  steps := steps || jsonb_build_object('n', 0, 'name', 'Niche + 15 trades', 'quota', '15 business models, approved', 'deadline', 3,
    'progress', case when p.niche_approved_at is not null then 'Approved' when p.niche_note is not null then 'Sent back' when p.niche_submitted_at is not null then 'Waiting for review' else 'Not sent yet' end, 'met', ok);

  -- 1: 300 contractors with phone + source link, 20 in each of 15 trades, by day 14
  select coalesce(sum(n), 0), count(*) filter (where n >= 20 and trade_id is not null) into v1, v2 from (
    select c.trade_id, count(*) n from public.contractors c
    where c.farmer_id = f and c.created_at <= t0 + interval '14 days' and coalesce(c.phone, '') <> '' and coalesce(c.source_link, '') <> ''
    group by c.trade_id) x;
  steps := steps || jsonb_build_object('n', 1, 'name', 'Contractor Identified', 'quota', '300 contractors (20 in each of 15 trades), with phone and source link', 'deadline', 14,
    'progress', v1 || ' of 300 · ' || v2 || ' of 15 trades at 20', 'met', v1 >= 300 and v2 >= 15);

  -- 2: 300 contractors called by day 21; every "agreed" call has the 20% text
  select count(*), count(*) filter (where said_yes and not texted) into v1, v2 from (
    select a.contractor_id, bool_or(a.outcome = 'agreed') said_yes, bool_or(a.text_sent) texted
    from public.activities a where a.farmer_id = f and a.kind = 'call' and a.contractor_id is not null
      and a.created_at <= t0 + interval '21 days' group by a.contractor_id) x;
  steps := steps || jsonb_build_object('n', 2, 'name', 'Outreach Made', 'quota', '300 calls, plus the 20% text to every yes', 'deadline', 21,
    'progress', v1 || ' of 300 called' || case when v2 > 0 then ' · ' || v2 || ' yes without the 20% text' else '' end, 'met', v1 >= 300 and v2 = 0);

  -- 3: 150 contractors at Terms Agreed (stage 3+), 10 in each of 15 trades, by day 45
  select coalesce(sum(n), 0), count(*) filter (where n >= 10 and trade_id is not null) into v1, v2 from (
    select c.trade_id, count(*) n from public.contractors c
    where c.farmer_id = f and exists (select 1 from public.contractor_stage_history h
      where h.contractor_id = c.id and h.to_stage >= 3 and h.changed_at <= t0 + interval '45 days')
    group by c.trade_id) x;
  steps := steps || jsonb_build_object('n', 3, 'name', 'Terms Agreed', 'quota', '150 agreed, 10 in each of 15 trades', 'deadline', 45,
    'progress', v1 || ' of 150 · ' || v2 || ' of 15 trades at 10', 'met', v1 >= 150 and v2 >= 15);

  -- 4: 50 comments a day on 5 days of every week from day 7 to day 90; 300 leads to 100+ contractors by day 75
  select count(*) filter (where good_days >= 5) into v3 from (
    select w, (select count(*) from (
        select date_trunc('day', a.created_at - t0) dd from public.activities a
        where a.farmer_id = f and a.kind = 'comments'
          and a.created_at >= t0 + make_interval(days => 7 + 7 * w) and a.created_at < t0 + make_interval(days => 14 + 7 * w)
        group by 1 having sum(a.count) >= 50) z) good_days
    from generate_series(0, 11) w) y;
  select count(*), count(distinct l.contractor_id) into v1, v2 from public.leads l
    where l.farmer_id = f and l.direction = 'outbound' and l.created_at <= t0 + interval '75 days';
  steps := steps || jsonb_build_object('n', 4, 'name', 'First Lead Sent', 'quota', '50 comments a day, 5 days a week (days 7 to 90); 300 leads to 100+ contractors by day 75', 'deadline', 75,
    'progress', v3 || ' of 12 comment weeks · ' || v1 || ' of 300 leads · ' || v2 || ' of 100 contractors', 'met', v3 >= 12 and v1 >= 300 and v2 >= 100);

  -- referral fees earned on jobs closed by day 90 (paid or not, so holding off on "paid" can't grow the refund);
  -- the refund is $500 minus these
  select coalesce(sum(l.fee_amount), 0) into fees from public.leads l
    where l.farmer_id = f and l.direction = 'outbound' and l.status = 'closed' and coalesce(l.closed_at, l.created_at) <= t0 + interval '90 days';

  -- rules: activity on 5 of every 7 days (13 weeks, days 0-90); quizzes for every level reached
  select count(*) filter (where days >= least(5, len)) into v1 from (
    select w, least(7, 91 - 7 * w) len, (select count(distinct floor(extract(epoch from x.t - t0) / 86400)) from (
        select created_at t from public.contractors where farmer_id = f
        union all select created_at from public.leads where farmer_id = f
        union all select created_at from public.activities where farmer_id = f
        union all select created_at from public.upsells where farmer_id = f
        union all select h.changed_at from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = f) x
      where x.t >= t0 + make_interval(days => 7 * w) and x.t < t0 + make_interval(days => least(7 * w + 7, 91))) days
    from generate_series(0, 12) w) y;
  select count(distinct q.quiz) into v2 from public.quiz_passes q where q.farmer_id = f
    and q.quiz in (select 'l' || g from generate_series(1, greatest(p.level, 1)) g);

  return jsonb_build_object(
    'enrolled', true, 'paid_at', t0, 'day', d,
    'end_at', t0 + interval '90 days', 'submit_by', t0 + interval '97 days',
    'steps', steps,
    'rules', jsonb_build_array(
      jsonb_build_object('name', 'Portal activity on 5 of every 7 days', 'progress', v1 || ' of 13 weeks', 'met', v1 >= 13),
      jsonb_build_object('name', 'Quizzes aced for every level reached', 'progress', v2 || ' of ' || greatest(p.level, 1), 'met', v2 >= greatest(p.level, 1))),
    'all_met', not exists (select 1 from jsonb_array_elements(steps) s where not (s->>'met')::boolean) and v1 >= 13 and v2 >= greatest(p.level, 1),
    'fees', fees, 'refund_amount', greatest(0, 500 - fees),
    'niche', p.niche, 'niche_note', p.niche_note,
    'comments_today', (select coalesce(sum(a.count), 0) from public.activities a
      where a.farmer_id = f and a.kind = 'comments' and a.created_at >= date_trunc('day', now())));
end $$;

create or replace function public.submit_refund_package(p_note text, p_files text[] default '{}') returns uuid
language plpgsql security definer set search_path = public as $$
declare pr jsonb; rid uuid;
begin
  pr := public.refund_progress(auth.uid());
  if not coalesce((pr->>'enrolled')::boolean, false) then raise exception 'Finish your enrollment first'; end if;
  if now() > (pr->>'submit_by')::timestamptz then raise exception 'The refund window closed on day 97'; end if;
  if not (pr->>'all_met')::boolean then raise exception 'Every quota has to be met before you can send the package'; end if;
  if (pr->>'refund_amount')::numeric <= 0 then raise exception 'Your referral fees reached $500, so no refund is owed'; end if;
  if coalesce(cardinality(p_files), 0) = 0 then raise exception 'Attach your evidence files'; end if;
  if exists (select 1 from unnest(p_files) x where x not like auth.uid()::text || '/%') then
    raise exception 'Evidence files must be your own uploads';
  end if;
  if exists (select 1 from public.refund_requests where farmer_id = auth.uid() and status in ('pending', 'approved')) then
    raise exception 'Your refund package was already sent';
  end if;
  insert into public.refund_requests (farmer_id, note, files, progress)
  values (auth.uid(), nullif(btrim(p_note), ''), p_files, pr) returning id into rid;
  return rid;
end $$;
