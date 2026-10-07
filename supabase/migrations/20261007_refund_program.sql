-- 90-day refund program (quotas approved by Alex 2026-10-07; spec in project files curriculum/refund-quotas.md).
-- Day 0 = the day the $500 is paid (profiles.enrolled_at). Every quota counts only what was logged in the
-- portal by its deadline, using server timestamps, so nothing can be backdated or bulk-entered at the end.

-- ---------- server-side timestamps ----------
alter table public.contractors add column source_link text;   -- the post/profile where the contractor was found
alter table public.leads add column fee_paid_at timestamptz;
alter table public.upsells add column closed_at timestamptz;

create or replace function public.stamp_times() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then return new; end if;              -- admins may correct records by hand
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
  end if;
  if tg_table_name = 'leads' then
    if new.status = 'closed' and (tg_op = 'INSERT' or old.status is distinct from 'closed') then new.closed_at := now();
    elsif new.status <> 'closed' then new.closed_at := null;
    elsif tg_op = 'UPDATE' then new.closed_at := old.closed_at; end if;
    if new.fee_paid and (tg_op = 'INSERT' or not old.fee_paid) then new.fee_paid_at := now();
    elsif not new.fee_paid then new.fee_paid_at := null;
    elsif tg_op = 'UPDATE' then new.fee_paid_at := old.fee_paid_at; end if;
  elsif tg_table_name = 'upsells' then
    if new.status = 'closed' and (tg_op = 'INSERT' or old.status is distinct from 'closed') then new.closed_at := now();
    elsif new.status <> 'closed' then new.closed_at := null;
    elsif tg_op = 'UPDATE' then new.closed_at := old.closed_at; end if;
  end if;
  return new;
end $$;
create trigger contractors_stamp before insert or update on public.contractors for each row execute function public.stamp_times();
create trigger leads_stamp before insert or update on public.leads for each row execute function public.stamp_times();
create trigger upsells_stamp before insert or update on public.upsells for each row execute function public.stamp_times();

-- ---------- activity log: calls and daily neighbor comments ----------
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  contractor_id uuid references public.contractors(id) on delete set null,
  kind text not null check (kind in ('call', 'comments')),
  outcome text check (outcome in ('agreed', 'not interested', 'no answer', 'call back')),
  text_sent boolean not null default false,  -- the 20% follow-up text, for calls that ended in a yes
  count int not null default 1 check (count between 1 and 1000),  -- comments posted, for kind = comments
  created_at timestamptz not null default now()
);
alter table public.activities enable row level security;
create policy "own activities" on public.activities for all to authenticated
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()
    and (contractor_id is null or exists (select 1 from public.contractors c where c.id = contractor_id and c.farmer_id = auth.uid())))
    or public.is_admin());
create policy "verifier reads activities" on public.activities for select to authenticated using (public.is_verifier());
create trigger activities_stamp before insert or update on public.activities for each row execute function public.stamp_times();

-- ---------- step 0: the farmer's 15 business models, approved by Alex or a verifier ----------
alter table public.profiles add column niche text;               -- one business model per line
alter table public.profiles add column niche_submitted_at timestamptz;
alter table public.profiles add column niche_approved_at timestamptz;
alter table public.profiles add column niche_note text;          -- reviewer's note when sent back

create or replace function public.submit_niche(p_list text) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.has_access() then raise exception 'Finish your enrollment first'; end if;
  select count(distinct lower(btrim(x))) into n from unnest(string_to_array(coalesce(p_list, ''), E'\n')) x where btrim(x) <> '';
  if n < 15 then raise exception 'List 15 different business models, one per line (you have %)', n; end if;
  if exists (select 1 from public.profiles where id = auth.uid() and niche_approved_at is not null) then
    raise exception 'Your 15 are already approved';
  end if;
  update public.profiles set niche = btrim(p_list), niche_submitted_at = now(), niche_note = null where id = auth.uid();
end $$;

create or replace function public.niche_queue()
returns table (id uuid, full_name text, email text, niche text, niche_submitted_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select p.id, p.full_name, p.email, p.niche, p.niche_submitted_at from public.profiles p
    where p.niche_submitted_at is not null and p.niche_approved_at is null and p.niche_note is null order by p.niche_submitted_at;
end $$;

create or replace function public.review_niche(p_farmer uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  if p_farmer = auth.uid() and not public.is_admin() then raise exception 'You can''t approve your own list'; end if;
  if p_approve then
    update public.profiles set niche_approved_at = now(), niche_note = null where id = p_farmer;
  else
    update public.profiles set niche_note = coalesce(nullif(btrim(p_note), ''), 'Sent back') where id = p_farmer;
  end if;
end $$;

-- ---------- quota progress ----------
-- One row per quota and rule. "by day N" = logged no later than N days after payment.
create or replace function public.refund_progress(p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f uuid := coalesce(p_farmer, auth.uid());
  p public.profiles;
  t0 timestamptz;
  d int;
  steps jsonb := '[]';
  v1 int; v2 int; v3 int; ok boolean;
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

  -- 5: 30 paid referral fees from 20+ contractors in 10+ trades by day 90
  select count(*), count(distinct l.contractor_id), count(distinct c.trade_id) into v1, v2, v3
    from public.leads l left join public.contractors c on c.id = l.contractor_id
    where l.farmer_id = f and l.direction = 'outbound' and l.status = 'closed' and l.fee_paid and l.fee_paid_at <= t0 + interval '90 days';
  steps := steps || jsonb_build_object('n', 5, 'name', 'First Lead Closed', 'quota', '30 paid fees, 20+ contractors, 10+ trades', 'deadline', 90,
    'progress', v1 || ' of 30 fees · ' || v2 || ' of 20 contractors · ' || v3 || ' of 10 trades', 'met', v1 >= 30 and v2 >= 20 and v3 >= 10);

  -- 6: contractors in 10 different trades each sending 3+ leads back by day 90
  select count(distinct c.trade_id) into v1 from public.contractors c
    where c.farmer_id = f and c.trade_id is not null and (select count(*) from public.leads l
      where l.contractor_id = c.id and l.direction = 'inbound' and l.created_at <= t0 + interval '90 days') >= 3;
  steps := steps || jsonb_build_object('n', 6, 'name', 'Reciprocal Active', 'quota', '10 contractors in 10 trades, each sending 3+ leads back', 'deadline', 90,
    'progress', v1 || ' of 10 trades', 'met', v1 >= 10);

  -- 7: anchors = 3+ jobs closed and paid + 1+ lead back by day 80; need 5 trades
  -- 8: an anchor pitched in each of those 5 trades by day 85
  with a as (select c.id, c.trade_id from public.contractors c
    where c.farmer_id = f and c.trade_id is not null
      and (select count(*) from public.leads l where l.contractor_id = c.id and l.direction = 'outbound' and l.status = 'closed'
           and l.fee_paid and l.fee_paid_at <= t0 + interval '80 days') >= 3
      and exists (select 1 from public.leads l where l.contractor_id = c.id and l.direction = 'inbound' and l.created_at <= t0 + interval '80 days'))
  select count(distinct a.trade_id),
    count(distinct a.trade_id) filter (where exists (select 1 from public.upsells u where u.contractor_id = a.id and u.created_at <= t0 + interval '85 days'))
    into v1, v2 from a;
  steps := steps || jsonb_build_object('n', 7, 'name', 'Anchor Status', 'quota', '5 anchors in 5 trades (3+ paid jobs and 1+ lead back each)', 'deadline', 80,
    'progress', v1 || ' of 5 trades', 'met', v1 >= 5);
  steps := steps || jsonb_build_object('n', 8, 'name', 'Upsell Pitched', 'quota', 'All 5 anchors pitched', 'deadline', 85,
    'progress', v2 || ' of 5 pitched', 'met', v1 >= 5 and v2 >= 5);

  -- 9: 1 upsell closed by day 90
  select count(*) into v1 from public.upsells u
    where u.farmer_id = f and u.status = 'closed' and u.closed_at <= t0 + interval '90 days';
  steps := steps || jsonb_build_object('n', 9, 'name', 'Upsell Closed', 'quota', '1 upsell closed', 'deadline', 90,
    'progress', v1 || ' of 1', 'met', v1 >= 1);

  -- rules: activity on 5 of every 7 days (13 weeks, days 0-90); quizzes; level 3
  select count(*) filter (where days >= least(5, len)) into v1 from (
    select w, least(7, 91 - 7 * w) len, (select count(distinct floor(extract(epoch from x.t - t0) / 86400)) from (
        select created_at t from public.contractors where farmer_id = f
        union all select created_at from public.leads where farmer_id = f
        union all select created_at from public.activities where farmer_id = f
        union all select created_at from public.upsells where farmer_id = f
        union all select h.changed_at from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = f) x
      where x.t >= t0 + make_interval(days => 7 * w) and x.t < t0 + make_interval(days => least(7 * w + 7, 91))) days
    from generate_series(0, 12) w) y;
  select count(*) into v2 from public.quiz_passes q where q.farmer_id = f and q.quiz in ('l1', 'l2', 'l3');

  return jsonb_build_object(
    'enrolled', true, 'paid_at', t0, 'day', d,
    'end_at', t0 + interval '90 days', 'submit_by', t0 + interval '97 days',
    'steps', steps,
    'rules', jsonb_build_array(
      jsonb_build_object('name', 'Portal activity on 5 of every 7 days', 'progress', v1 || ' of 13 weeks', 'met', v1 >= 13),
      jsonb_build_object('name', 'Level 1, 2 and 3 quizzes aced', 'progress', v2 || ' of 3', 'met', v2 >= 3),
      jsonb_build_object('name', 'Reached Level 3 (every level-up approved)', 'progress', 'Level ' || p.level, 'met', p.level >= 3)),
    'all_met', not exists (select 1 from jsonb_array_elements(steps) s where not (s->>'met')::boolean) and v1 >= 13 and v2 >= 3 and p.level >= 3,
    'niche', p.niche, 'niche_note', p.niche_note,
    'comments_today', (select coalesce(sum(a.count), 0) from public.activities a
      where a.farmer_id = f and a.kind = 'comments' and a.created_at >= date_trunc('day', now())));
end $$;

-- ---------- the refund package ----------
create table public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  note text,
  files text[] not null default '{}',     -- evidence in the private "proof" bucket
  progress jsonb not null,                -- the quota check at the moment it was sent
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  reviewer_id uuid references public.profiles(id),
  review_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index refund_requests_one_open on public.refund_requests (farmer_id) where status in ('pending', 'approved');
alter table public.refund_requests enable row level security;
create policy "refund read" on public.refund_requests for select to authenticated using (farmer_id = auth.uid() or public.is_verifier());

create or replace function public.submit_refund_package(p_note text, p_files text[] default '{}') returns uuid
language plpgsql security definer set search_path = public as $$
declare pr jsonb; rid uuid;
begin
  pr := public.refund_progress(auth.uid());
  if not coalesce((pr->>'enrolled')::boolean, false) then raise exception 'Finish your enrollment first'; end if;
  if now() > (pr->>'submit_by')::timestamptz then raise exception 'The refund window closed on day 97'; end if;
  if not (pr->>'all_met')::boolean then raise exception 'Every quota has to be met before you can send the package'; end if;
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

create or replace function public.refund_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, note text, files text[], progress jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select r.id, r.farmer_id, p.full_name, p.email, r.note, r.files, r.progress, r.created_at
    from public.refund_requests r join public.profiles p on p.id = r.farmer_id where r.status = 'pending' order by r.created_at;
end $$;

create or replace function public.review_refund(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.refund_requests;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into r from public.refund_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This package was already handled'; end if;
  if r.farmer_id = auth.uid() and not public.is_admin() then raise exception 'You can''t review your own package'; end if;
  update public.refund_requests set status = case when p_approve then 'approved' else 'denied' end,
    reviewer_id = auth.uid(), review_note = nullif(btrim(p_note), ''), reviewed_at = now() where id = p_id;
end $$;

-- Everything the package is checked against, straight from the CRM, for the reviewer's spot checks
create or replace function public.refund_evidence(p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f uuid := coalesce(p_farmer, auth.uid());
begin
  if f <> auth.uid() and not public.is_verifier() then raise exception 'verifiers only'; end if;
  return jsonb_build_object(
    'contractors', coalesce((select jsonb_agg(jsonb_build_object('business', c.business_name, 'contact', c.contact_name, 'phone', c.phone,
        'trade', t.name, 'stage', c.stage, 'source_link', c.source_link, 'logged', c.created_at) order by c.created_at)
      from public.contractors c left join public.trades t on t.id = c.trade_id where c.farmer_id = f), '[]'),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('business', c.business_name, 'phone', c.phone, 'outcome', a.outcome,
        'text_sent', a.text_sent, 'logged', a.created_at) order by a.created_at)
      from public.activities a left join public.contractors c on c.id = a.contractor_id where a.farmer_id = f and a.kind = 'call'), '[]'),
    'comments', coalesce((select jsonb_agg(jsonb_build_object('count', a.count, 'logged', a.created_at) order by a.created_at)
      from public.activities a where a.farmer_id = f and a.kind = 'comments'), '[]'),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('direction', l.direction, 'business', c.business_name, 'customer', l.customer_name,
        'job', l.job_description, 'status', l.status, 'job_value', l.job_value, 'fee', l.fee_amount, 'fee_paid', l.fee_paid,
        'logged', l.created_at, 'closed', l.closed_at, 'fee_paid_at', l.fee_paid_at) order by l.created_at)
      from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = f), '[]'),
    'upsells', coalesce((select jsonb_agg(jsonb_build_object('business', c.business_name, 'product', u.product, 'status', u.status,
        'amount', u.amount, 'logged', u.created_at, 'closed', u.closed_at) order by u.created_at)
      from public.upsells u join public.contractors c on c.id = u.contractor_id where u.farmer_id = f), '[]'));
end $$;

revoke execute on function public.refund_evidence(uuid) from public, anon;
grant execute on function public.refund_evidence(uuid) to authenticated;
revoke execute on function public.submit_niche(text), public.niche_queue(), public.review_niche(uuid, boolean, text),
  public.refund_progress(uuid), public.submit_refund_package(text, text[]), public.refund_queue(),
  public.review_refund(uuid, boolean, text), public.stamp_times() from public, anon;
revoke execute on function public.stamp_times() from authenticated;  -- trigger only
grant execute on function public.submit_niche(text), public.niche_queue(), public.review_niche(uuid, boolean, text),
  public.refund_progress(uuid), public.submit_refund_package(text, text[]), public.refund_queue(),
  public.review_refund(uuid, boolean, text) to authenticated;
