-- Booking funnel (Alex, 2026-10-14): the landing page asks a few questions (18+, town, why), then shows
-- Alex's Cal.com calendar. Each request and booking is one row here; Cal.com's webhook (edge function
-- booking-webhook) fills in the call time. Alex marks who showed up; a booked person who later pays is
-- marked enrolled on its own. Telegram alerts for each form and each booking.
create table if not exists public.call_requests (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (length(btrim(full_name)) between 1 and 120),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 200),
  phone text check (length(phone) <= 40),
  town text check (length(town) <= 120),
  why text check (length(why) <= 2000),
  adult boolean not null check (adult),
  meta jsonb not null default '{}',       -- where they came from: utm_*, ref, landing page (group 5)
  status text not null default 'requested' check (status in ('requested', 'booked', 'canceled', 'showed', 'no_show', 'enrolled')),
  call_at timestamptz,
  cal_uid text unique,
  profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  booked_at timestamptz);
create index if not exists call_requests_email on public.call_requests (lower(email), created_at desc);
alter table public.call_requests enable row level security;
create policy "calls admin read" on public.call_requests for select using (public.is_admin());

-- The landing page's pre-call form (anyone, signed in or not). A few per email per hour at most.
create or replace function public.request_call(p_name text, p_email text, p_phone text, p_town text, p_why text, p_adult boolean, p_meta jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if not coalesce(p_adult, false) then raise exception 'You need to be 18 or older'; end if;
  if (select count(*) from public.call_requests where lower(email) = lower(btrim(p_email)) and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'We already have your request. Pick a time on the calendar, or email support@leadfarminghq.com';
  end if;
  insert into public.call_requests (full_name, email, phone, town, why, adult, meta)
  values (btrim(p_name), lower(btrim(p_email)), nullif(btrim(p_phone), ''), nullif(btrim(p_town), ''), nullif(btrim(p_why), ''), true,
    coalesce((select jsonb_object_agg(k, left(v, 300)) from jsonb_each_text(coalesce(p_meta, '{}')) x(k, v) where k ~ '^[a-z_]{1,40}$'), '{}'))
  returning id into rid;
  return rid;
end $$;
revoke execute on function public.request_call(text, text, text, text, text, boolean, jsonb) from public;
grant execute on function public.request_call(text, text, text, text, text, boolean, jsonb) to anon, authenticated;

-- Admin: calls from the last 30 days and everything upcoming
create or replace function public.call_board() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((select jsonb_agg(to_jsonb(c) - 'adult' order by coalesce(c.call_at, c.created_at) desc)
    from public.call_requests c where coalesce(c.call_at, c.created_at) > now() - interval '30 days'), '[]');
end $$;
revoke execute on function public.call_board() from public, anon;
grant execute on function public.call_board() to authenticated;

create or replace function public.mark_call(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_status not in ('booked', 'canceled', 'showed', 'no_show') then raise exception 'bad status'; end if;
  update public.call_requests set status = p_status where id = p_id;
end $$;
revoke execute on function public.mark_call(uuid, text) from public, anon;
grant execute on function public.mark_call(uuid, text) to authenticated;

-- A booked person who pays is enrolled (matched on email)
create or replace function public.on_paid_match_call() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.enrollment_paid and not old.enrollment_paid then
    update public.call_requests set status = 'enrolled', profile_id = new.id
      where lower(email) = lower(new.email) and status in ('requested', 'booked', 'showed', 'no_show');
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists match_call on public.profiles;
create trigger match_call after update of enrollment_paid on public.profiles
  for each row execute function public.on_paid_match_call();

-- Telegram: a new pre-call form, and each booking or cancellation from Cal.com
create or replace function ops.on_call_event() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare msg text; t text;
begin
  begin
    t := to_char(new.call_at at time zone 'America/Chicago', 'Dy Mon DD, HH12:MI AM') || ' Central';
    if tg_op = 'INSERT' then
      msg := '📝 Call request: ' || new.full_name || coalesce(' · ' || new.town, '') || coalesce(' · ' || new.phone, '') || ' · ' || new.email
        || coalesce(E'\nWhy: "' || left(new.why, 400) || '"', '')
        || coalesce(E'\nFrom: ' || nullif(concat_ws(' / ', new.meta->>'utm_source', new.meta->>'utm_campaign', new.meta->>'ref'), ''), '')
        || case when new.status = 'booked' then E'\n📅 Booked: ' || t else E'\nThey were shown your calendar next.' end;
    elsif new.status = 'booked' and (old.status is distinct from 'booked' or new.call_at is distinct from old.call_at) then
      msg := '📅 Call booked: ' || new.full_name || coalesce(' · ' || new.town, '') || coalesce(' · ' || new.phone, '') || E'\n' || coalesce(t, 'time not given')
        || coalesce(E'\nWhy: "' || left(new.why, 400) || '"', '');
    elsif new.status = 'canceled' and old.status is distinct from 'canceled' then
      msg := '❌ Call canceled: ' || new.full_name || coalesce(' (' || t || ')', '');
    end if;
    if msg is not null then perform ops.telegram(msg); end if;
  exception when others then
    raise warning 'telegram alert failed: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists telegram_alert on public.call_requests;
create trigger telegram_alert after insert or update of status, call_at on public.call_requests
  for each row execute function ops.on_call_event();

-- Cal.com webhook (called by the edge function with the service role): record a booking, reschedule or cancellation.
-- Matches the latest form from the same email; a booking with no form (direct calendar link) gets its own row.
create or replace function public.record_booking(p_event text, p_uid text, p_email text, p_name text, p_start timestamptz, p_notes text, p_old_uid text default null)
returns void language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  select id into rid from public.call_requests where cal_uid = p_uid or cal_uid = p_old_uid order by cal_uid = p_uid desc limit 1;  -- a reschedule names the old booking
  if rid is null and p_event <> 'BOOKING_CANCELLED' then
    select id into rid from public.call_requests where lower(email) = lower(p_email) and cal_uid is null and status = 'requested'
      order by created_at desc limit 1;
  end if;
  if p_event = 'BOOKING_CANCELLED' then
    update public.call_requests set status = 'canceled' where id = rid;
  elsif rid is null then
    insert into public.call_requests (full_name, email, why, adult, status, call_at, cal_uid, booked_at)
    values (coalesce(nullif(btrim(p_name), ''), p_email), lower(p_email), nullif(left(p_notes, 2000), ''), true, 'booked', p_start, p_uid, now());
  else
    update public.call_requests set status = 'booked', call_at = p_start, cal_uid = p_uid, booked_at = coalesce(booked_at, now()) where id = rid;
  end if;
end $$;
revoke execute on function public.record_booking(text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.record_booking(text, text, text, text, timestamptz, text, text) to service_role;
