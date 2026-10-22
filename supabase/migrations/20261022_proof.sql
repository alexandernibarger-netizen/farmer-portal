-- ---------- Proof: fees, testimonials and the wins feed (20261022_proof.sql) ----------
-- Only adds things. No existing row is changed or deleted. The new triggers on contractor_stage_history,
-- profiles and leads read those tables and write only into the new ones (plus a portal notification).
-- The one existing function touched is ops.decide, which gets two new Telegram button kinds (fee, testimonial).

-- ---------- private bucket for fee screenshots and testimonial media ----------
-- Members upload into a folder named by their user id. Only they and Alex can read it.
-- No update or delete policy, so a screenshot stays as proof once it's uploaded.
insert into storage.buckets (id, name, public, file_size_limit)
values ('wins', 'wins', false, 52428800) on conflict (id) do nothing;
drop policy if exists "wins upload own" on storage.objects;
create policy "wins upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'wins' and (storage.foldername(name))[1] = auth.uid()::text and public.has_access());
drop policy if exists "wins read own or admin" on storage.objects;
create policy "wins read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'wins' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- fees a member got paid ----------
create table if not exists public.fees (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  contractor_id uuid references public.contractors(id) on delete set null,
  lead_id uuid references public.leads(id) on delete set null,
  job_amount numeric(12,2) check (job_amount >= 0),
  fee_pct numeric(5,2) check (fee_pct between 0 and 100),
  fee_amount numeric(12,2) not null check (fee_amount > 0),
  paid_at date not null default current_date,      -- the day the contractor paid the member
  proof_url text,                                  -- path in the wins bucket: <farmer id>/fees/<file>
  note text,
  verified boolean not null default false,
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  review_note text,                                -- why it was sent back
  created_at timestamptz not null default now()
);
create index if not exists fees_farmer on public.fees (farmer_id, paid_at);
alter table public.fees enable row level security;
drop policy if exists "own fees read" on public.fees;
create policy "own fees read" on public.fees for select to authenticated
  using (farmer_id = auth.uid() or public.is_admin());
drop policy if exists "own fees add" on public.fees;
create policy "own fees add" on public.fees for insert to authenticated
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());
drop policy if exists "own fees edit" on public.fees;
create policy "own fees edit" on public.fees for update to authenticated
  using ((farmer_id = auth.uid() and not verified) or public.is_admin())
  with check ((farmer_id = auth.uid() and not verified) or public.is_admin());
drop policy if exists "own fees delete" on public.fees;
create policy "own fees delete" on public.fees for delete to authenticated
  using ((farmer_id = auth.uid() and not verified) or public.is_admin());

-- Members can't verify their own fee, move it to someone else, or edit it once Alex verified it.
create or replace function public.fees_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.fee_amount is null and new.job_amount is not null and new.fee_pct is not null then
    new.fee_amount := round(new.job_amount * new.fee_pct / 100, 2);
  end if;
  if public.is_admin() or auth.uid() is null then return new; end if;   -- Alex, or the database itself
  if tg_op = 'UPDATE' and old.verified then raise exception 'This fee is verified and locked. Ask Alex to change it.'; end if;
  new.farmer_id := auth.uid();
  new.verified := false; new.verified_by := null; new.verified_at := null;
  if tg_op = 'UPDATE' then new.review_note := old.review_note; end if;
  if new.contractor_id is not null and not exists (select 1 from public.contractors where id = new.contractor_id and farmer_id = auth.uid()) then
    raise exception 'That contractor isn''t on your list';
  end if;
  if new.lead_id is not null and not exists (select 1 from public.leads where id = new.lead_id and farmer_id = auth.uid()) then
    raise exception 'That lead isn''t yours';
  end if;
  return new;
end $$;
drop trigger if exists fees_guard on public.fees;
create trigger fees_guard before insert or update on public.fees for each row execute function public.fees_guard();

-- ---------- testimonials ----------
create table if not exists public.testimonials (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  trigger_event text not null check (trigger_event in
    ('terms_agreed', 'first_lead_sent', 'first_lead_closed', 'fee_verified', 'level_up', 'day_90', 'manual')),
  trigger_key text not null,                       -- one request per win: 'stage:3', 'fee:<id>', 'level:2', 'day_90'
  trigger_detail jsonb not null default '{}',      -- what the win was, for the prompt and the feed
  contractor_id uuid references public.contractors(id) on delete set null,
  fee_id uuid references public.fees(id) on delete set null,
  quote text,
  video_url text,                                  -- wins bucket path or a link (YouTube, Loom...)
  screenshot_url text,
  rating smallint check (rating between 1 and 5),
  before_text text,
  after_text text,
  ad_consent boolean not null default false,
  consent_at timestamptz,
  status text not null default 'requested' check (status in ('requested', 'submitted', 'approved', 'rejected')),
  requested_at timestamptz not null default now(),
  submitted_at timestamptz,
  dismissed_at timestamptz,                        -- member tapped "not now": hide the card, keep the request
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  unique (farmer_id, trigger_key)
);
create index if not exists testimonials_status on public.testimonials (status, submitted_at);
alter table public.testimonials enable row level security;
drop policy if exists "own testimonials read" on public.testimonials;
create policy "own testimonials read" on public.testimonials for select to authenticated
  using (farmer_id = auth.uid() or public.is_admin());
drop policy if exists "admin testimonials" on public.testimonials;
create policy "admin testimonials" on public.testimonials for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- members write only through submit_testimonial / set_testimonial_consent / dismiss_testimonial below
revoke insert, update, delete on public.testimonials from authenticated, anon;

-- ---------- asking for a testimonial when a member hits a win ----------
create or replace function ops.win_label(ev text, d jsonb) returns text
language sql immutable as $$
  select case ev
    when 'terms_agreed' then 'Your first contractor agreed to terms' || coalesce(' (' || (d->>'contractor') || ')', '')
    when 'first_lead_sent' then 'You sent your first lead' || coalesce(' to ' || (d->>'contractor'), '')
    when 'first_lead_closed' then 'Your first lead closed' || coalesce(' with ' || (d->>'contractor'), '')
    when 'fee_verified' then 'Your ' || ops.money((d->>'fee')::numeric) || ' fee is verified'
    when 'level_up' then 'You reached Level ' || (d->>'level')
    when 'day_90' then 'You made it to day 90'
    else 'You had a win' end;
$$;

-- One request per win. Best effort: never blocks the action that caused it.
create or replace function ops.request_testimonial(f uuid, ev text, k text, d jsonb default '{}',
  p_contractor uuid default null, p_fee uuid default null) returns void
language plpgsql security definer set search_path = ops, public as $$
declare t uuid;
begin
  if not exists (select 1 from public.profiles where id = f and role = 'farmer' and enrollment_paid and not coalesce(comp, false)) then
    return;   -- only paying members (no admin, no comp accounts)
  end if;
  insert into public.testimonials (farmer_id, trigger_event, trigger_key, trigger_detail, contractor_id, fee_id)
    values (f, ev, k, coalesce(d, '{}'), p_contractor, p_fee)
    on conflict (farmer_id, trigger_key) do nothing returning id into t;
  if t is null then return; end if;
  -- in the portal, and (through the existing notifications trigger) a Discord DM when they're linked
  insert into public.notifications (farmer_id, body) values (f,
    '🎉 ' || ops.win_label(ev, d) || '! Got 2 minutes to tell your story? Open Home and tap "Share your win."');
exception when others then
  raise warning 'testimonial request failed: %', sqlerrm;
end $$;

-- contractor reaches stage 3, 4 or 5: the first time for this member, for each of those stages
create or replace function ops.on_proof_stage() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare c public.contractors; s smallint := least(new.to_stage, 5);
begin
  if new.to_stage < 3 or (new.from_stage is not null and new.from_stage >= s) then return null; end if;
  select * into c from public.contractors where id = new.contractor_id;
  if c.id is null then return null; end if;
  perform ops.request_testimonial(c.farmer_id,
    case s when 3 then 'terms_agreed' when 4 then 'first_lead_sent' else 'first_lead_closed' end,
    'stage:' || s, jsonb_build_object('contractor', c.business_name, 'stage', s, 'trade_id', c.trade_id), c.id, null);
  return null;
end $$;
drop trigger if exists proof_win on public.contractor_stage_history;
create trigger proof_win after insert on public.contractor_stage_history for each row execute function ops.on_proof_stage();

-- level up
create or replace function ops.on_proof_level() returns trigger
language plpgsql security definer set search_path = ops, public as $$
begin
  if coalesce(new.level, 0) > coalesce(old.level, 0) and new.level >= 2 then
    perform ops.request_testimonial(new.id, 'level_up', 'level:' || new.level, jsonb_build_object('level', new.level));
  end if;
  return null;
end $$;
drop trigger if exists proof_win on public.profiles;
create trigger proof_win after update of level on public.profiles for each row execute function ops.on_proof_level();

-- day 90, checked daily
create or replace function ops.proof_day90() returns void
language plpgsql security definer set search_path = ops, public as $$
declare f uuid;
begin
  for f in select id from public.profiles where role = 'farmer' and enrollment_paid and not coalesce(comp, false)
             and enrolled_at <= now() - interval '90 days' and enrolled_at > now() - interval '97 days' loop
    perform ops.request_testimonial(f, 'day_90', 'day_90', jsonb_build_object('enrolled_at', (select enrolled_at from public.profiles where id = f)));
  end loop;
end $$;
select cron.unschedule('proof-day-90') where exists (select 1 from cron.job where jobname = 'proof-day-90');
select cron.schedule('proof-day-90', '30 15 * * *', $$select ops.proof_day90()$$);

-- ---------- fee verification ----------
create or replace function public.verify_fee(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.fees;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into r from public.fees where id = p_id for update;
  if r.id is null then raise exception 'Fee not found'; end if;
  if r.verified then raise exception 'This fee was already verified'; end if;
  if p_approve then
    if r.proof_url is null then raise exception 'No payment screenshot yet. Ask them to upload one first.'; end if;
    update public.fees set verified = true, verified_by = auth.uid(), verified_at = now(), review_note = null where id = p_id;
    if r.lead_id is not null then   -- the lead it came from counts as closed and paid
      update public.leads set fee_paid = true, status = 'closed', closed_at = coalesce(closed_at, now()) where id = r.lead_id;
    end if;
    insert into public.notifications (farmer_id, body)
      values (r.farmer_id, '✅ Your ' || ops.money(r.fee_amount) || ' fee is verified.');
    perform ops.request_testimonial(r.farmer_id, 'fee_verified', 'fee:' || r.id,
      jsonb_build_object('fee', r.fee_amount, 'contractor', (select business_name from public.contractors where id = r.contractor_id)),
      r.contractor_id, r.id);
  else
    update public.fees set review_note = coalesce(nullif(btrim(p_note), ''), 'Alex couldn''t verify this one yet') where id = p_id;
    insert into public.notifications (farmer_id, body)
      values (r.farmer_id, '↩️ Your ' || ops.money(r.fee_amount) || ' fee wasn''t verified yet: '
        || coalesce(nullif(btrim(p_note), ''), 'check the screenshot and try again') || '. Fix it on the Money tab.');
  end if;
end $$;

-- ---------- member side of testimonials ----------
-- p_id null = a story they volunteer without a prompt
create or replace function public.submit_testimonial(p_id uuid, p_quote text, p_rating smallint,
  p_before text default null, p_after text default null, p_video_url text default null,
  p_screenshot_url text default null, p_consent boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.testimonials; i uuid := p_id;
begin
  if not public.has_access() then raise exception 'Not enrolled'; end if;
  if nullif(btrim(p_quote), '') is null then raise exception 'Write a sentence or two first'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Pick a rating from 1 to 5'; end if;
  if i is null then
    insert into public.testimonials (farmer_id, trigger_event, trigger_key)
      values (auth.uid(), 'manual', 'manual:' || gen_random_uuid()) returning id into i;
  end if;
  select * into r from public.testimonials where id = i and farmer_id = auth.uid() for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status = 'approved' then raise exception 'This one is already approved. Send a new one instead.'; end if;
  update public.testimonials set quote = btrim(p_quote), rating = p_rating,
      before_text = nullif(btrim(p_before), ''), after_text = nullif(btrim(p_after), ''),
      video_url = nullif(btrim(p_video_url), ''), screenshot_url = nullif(btrim(p_screenshot_url), ''),
      ad_consent = coalesce(p_consent, false),
      consent_at = case when coalesce(p_consent, false) then now() end,
      status = 'submitted', submitted_at = now(), dismissed_at = null, review_note = null
    where id = i;
  return i;
end $$;

-- They can take back ad consent at any time; it drops out of every export straight away.
create or replace function public.set_testimonial_consent(p_id uuid, p_consent boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.testimonials set ad_consent = p_consent, consent_at = case when p_consent then now() end
    where id = p_id and farmer_id = auth.uid() and status <> 'requested';
  if not found then raise exception 'Not found'; end if;
end $$;

create or replace function public.dismiss_testimonial(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update public.testimonials set dismissed_at = now() where id = p_id and farmer_id = auth.uid() and status = 'requested';
$$;

-- ---------- Alex's side ----------
create or replace function public.review_testimonial(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.testimonials;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into r from public.testimonials where id = p_id for update;
  if r.id is null then raise exception 'Not found'; end if;
  if r.status = 'requested' then raise exception 'They haven''t sent this one yet'; end if;
  if p_approve and not r.ad_consent then raise exception 'They didn''t agree to ads, so it can''t be approved for ads'; end if;
  update public.testimonials set status = case when p_approve then 'approved' else 'rejected' end,
    reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(btrim(p_note), '') where id = p_id;
  if p_approve and r.status <> 'approved' then
    insert into public.notifications (farmer_id, body)
      values (r.farmer_id, '⭐ Thanks for sharing your story! Alex picked it to show other people what''s possible.');
  end if;
end $$;

-- ---------- Telegram to Alex: Verify / Approve buttons ----------
create or replace function ops.on_proof_event() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare c text;
begin
  begin
    if tg_table_name = 'fees' and tg_op = 'INSERT' then
      select business_name into c from public.contractors where id = new.contractor_id;
      perform ops.ask('💵 Fee to verify: ' || ops.who(new.farmer_id) || ' got ' || ops.money(new.fee_amount)
        || coalesce(' from ' || c, '') || coalesce(' (job ' || ops.money(new.job_amount) || ')', '')
        || case when new.proof_url is null then E'\nNo screenshot yet.' else E'\nScreenshot is in the Proof tab.' end
        || E'\nhttps://leadfarminghq.com', 'fee', new.id, '✅ Verify', '❌ Not yet');
    elsif tg_table_name = 'testimonials' and new.status = 'submitted' and old.status is distinct from 'submitted' then
      if new.ad_consent then
        perform ops.ask('⭐ Testimonial from ' || ops.who(new.farmer_id) || ' (' || coalesce(new.rating::text, '?') || '/5): "'
          || left(new.quote, 400) || '"' || coalesce(E'\nBefore: ' || left(new.before_text, 200), '')
          || coalesce(E'\nAfter: ' || left(new.after_text, 200), '') || E'\nThey agreed to ad use.',
          'testimonial', new.id, '✅ Approve for ads', '❌ Reject');
      else
        perform ops.telegram('⭐ Testimonial from ' || ops.who(new.farmer_id) || ': "' || left(new.quote, 400)
          || E'"\nNo ad consent, so it stays private.');
      end if;
    end if;
  exception when others then
    raise warning 'proof telegram failed: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists telegram_alert on public.fees;
create trigger telegram_alert after insert on public.fees for each row execute function ops.on_proof_event();
drop trigger if exists telegram_alert on public.testimonials;
create trigger telegram_alert after update of status on public.testimonials for each row execute function ops.on_proof_event();

-- Teach ops.decide the two new buttons (same in-place patch as the teacher Telegram migration)
do $$ declare d text; a text := E'  elsif d.kind = ''test'' then'; begin
  d := pg_get_functiondef('ops.decide(ops.telegram_decisions, boolean, text)'::regprocedure);
  if position(a in d) = 0 then raise exception 'ops.decide changed; update this migration'; end if;
  if position('''testimonial''' in d) > 0 then return; end if;
  execute replace(d, a,
       E'  elsif d.kind = ''fee'' then\n'
    || E'    perform public.verify_fee(d.ref, yes, note);\n'
    || E'    return case when yes then ''✅ Fee verified'' else ''↩️ Sent back to them'' end;\n'
    || E'  elsif d.kind = ''testimonial'' then\n'
    || E'    perform public.review_testimonial(d.ref, yes, note);\n'
    || E'    return case when yes then ''✅ Approved for ads'' else ''❌ Rejected'' end;\n'
    || a);
end $$;

-- ---------- Proof tab data (admin only) ----------
-- Every win and testimonial in one list; the page filters by type, date, member and trade.
create or replace function public.proof_feed(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  with m as (
    select id, coalesce(nullif(btrim(full_name), ''), email) as name, enrolled_at, coalesce(comp, false) as comp
    from public.profiles where role = 'farmer'
  ), items as (
    -- contractor milestones (Terms Agreed and up)
    select 'stage' as type, h.changed_at as at, c.farmer_id, c.trade_id, h.id::text as ref,
      jsonb_build_object('stage', h.to_stage, 'stage_name', s.name, 'contractor', c.business_name) as detail
    from public.contractor_stage_history h
    join public.contractors c on c.id = h.contractor_id join public.stages s on s.id = h.to_stage
    where h.to_stage >= 3 and (h.from_stage is null or h.from_stage < h.to_stage)
    union all
    select 'fee', f.paid_at::timestamptz, f.farmer_id, c.trade_id, f.id::text,
      jsonb_build_object('fee', f.fee_amount, 'job', f.job_amount, 'pct', f.fee_pct, 'contractor', c.business_name,
        'verified', f.verified, 'verified_at', f.verified_at, 'proof_url', f.proof_url, 'note', f.note, 'review_note', f.review_note)
    from public.fees f left join public.contractors c on c.id = f.contractor_id
    union all
    select 'level_up', e.created_at, e.farmer_id, null, e.id::text, jsonb_build_object('level', e.detail->'to')
    from public.farmer_events e
    where e.kind = 'level_changed' and (e.detail->>'to')::int > coalesce((e.detail->>'from')::int, 0) and (e.detail->>'to')::int >= 2
    union all
    select 'day_90', m.enrolled_at + interval '90 days', m.id, null, m.id::text, '{}'::jsonb
    from m join public.profiles p on p.id = m.id
    where p.enrollment_paid and m.enrolled_at <= now() - interval '90 days'
    union all
    select 'testimonial', coalesce(t.submitted_at, t.requested_at), t.farmer_id, c.trade_id, t.id::text,
      jsonb_build_object('status', t.status, 'trigger_event', t.trigger_event, 'win', t.trigger_detail, 'quote', t.quote,
        'rating', t.rating, 'before', t.before_text, 'after', t.after_text, 'video_url', t.video_url,
        'screenshot_url', t.screenshot_url, 'ad_consent', t.ad_consent, 'consent_at', t.consent_at,
        'contractor', c.business_name, 'review_note', t.review_note)
    from public.testimonials t left join public.contractors c on c.id = t.contractor_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('type', i.type, 'at', i.at, 'ref', i.ref, 'farmer_id', i.farmer_id,
      'farmer', m.name, 'comp', m.comp, 'trade_id', i.trade_id, 'trade', t.name) || i.detail order by i.at desc), '[]')
    into out
  from items i join m on m.id = i.farmer_id left join public.trades t on t.id = i.trade_id
  where (p_from is null or i.at >= p_from) and (p_to is null or i.at < p_to + 1);
  return out;
end $$;

-- Headline numbers. Paying members only (no comp accounts), with how many reached each step so a median
-- of 2 people never reads like a promise.
create or replace function public.proof_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  with m as (
    select id, enrolled_at from public.profiles
    where role = 'farmer' and enrollment_paid and not coalesce(comp, false) and enrolled_at is not null
  ), firsts as (
    select m.id, m.enrolled_at,
      (select min(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id
        where c.farmer_id = m.id and h.to_stage >= 3) as signed,
      least((select min(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id
              where c.farmer_id = m.id and h.to_stage >= 4),
            (select min(l.created_at) from public.leads l where l.farmer_id = m.id and l.direction = 'outbound')) as lead,
      (select min(f.paid_at)::timestamptz from public.fees f where f.farmer_id = m.id and f.verified) as fee
    from m
  ), big as (
    select f.fee_amount, f.paid_at, coalesce(nullif(btrim(p.full_name), ''), p.email) as farmer, c.business_name as contractor
    from public.fees f join public.profiles p on p.id = f.farmer_id left join public.contractors c on c.id = f.contractor_id
    where f.verified order by f.fee_amount desc, f.paid_at limit 1
  )
  select jsonb_build_object(
    'members', (select count(*) from m),
    'verified_fees_total', (select coalesce(sum(fee_amount), 0) from public.fees where verified),
    'verified_fees_count', (select count(*) from public.fees where verified),
    'fees_waiting', (select count(*) from public.fees where not verified),
    'biggest_fee', (select to_jsonb(big) from big),
    'days_to_signed', (select percentile_cont(0.5) within group (order by extract(epoch from signed - enrolled_at) / 86400) from firsts where signed >= enrolled_at),
    'n_signed', (select count(*) from firsts where signed >= enrolled_at),
    'days_to_lead', (select percentile_cont(0.5) within group (order by extract(epoch from lead - enrolled_at) / 86400) from firsts where lead >= enrolled_at),
    'n_lead', (select count(*) from firsts where lead >= enrolled_at),
    'days_to_fee', (select percentile_cont(0.5) within group (order by extract(epoch from fee - enrolled_at) / 86400) from firsts where fee >= enrolled_at),
    'n_fee', (select count(*) from firsts where fee >= enrolled_at),
    'testimonials_waiting', (select count(*) from public.testimonials where status = 'submitted'),
    'approved_for_ads', (select count(*) from public.testimonials where status = 'approved' and ad_consent)
  ) into out;
  return out;
end $$;

-- What may go into an ad: approved AND the member agreed. Enforced here, not just in the page.
-- Names are first name + last initial.
create or replace function public.proof_export() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', t.id, 'member',
        split_part(btrim(coalesce(p.full_name, '')), ' ', 1)
          || coalesce(' ' || left(nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 2), ''), 1) || '.', ''),
        'trade', tr.name, 'win', t.trigger_event, 'win_detail', t.trigger_detail, 'quote', t.quote, 'rating', t.rating,
        'before', t.before_text, 'after', t.after_text, 'video_url', t.video_url, 'screenshot_url', t.screenshot_url,
        'verified_fee', f.fee_amount, 'consent_at', t.consent_at, 'approved_at', t.reviewed_at,
        'disclaimer', 'Results not typical. Individual results vary and depend on effort; earnings are not guaranteed.')
      order by t.reviewed_at desc)
    from public.testimonials t join public.profiles p on p.id = t.farmer_id
    left join public.contractors c on c.id = t.contractor_id left join public.trades tr on tr.id = c.trade_id
    left join public.fees f on f.id = t.fee_id and f.verified
    where t.status = 'approved' and t.ad_consent and t.consent_at is not null), '[]');
end $$;

revoke execute on function public.fees_guard() from public, anon, authenticated;
revoke execute on all functions in schema ops from public, anon, authenticated;
