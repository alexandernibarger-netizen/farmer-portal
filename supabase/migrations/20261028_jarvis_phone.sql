-- Jarvis phone assistant: call log + the database side of Jarvis's tools.
-- The jarvis edge function (Vapi tool calls) is the only caller: every function here is service_role only.

create table if not exists ops.jarvis_calls (
  call_id text primary key,
  caller text,
  verified_at timestamptz,
  bad_pins int not null default 0,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  summary text,
  transcript text
);

create table if not exists ops.jarvis_log (
  id bigint generated always as identity primary key,
  call_id text,
  tool text not null,
  args jsonb,
  result text,
  at timestamptz not null default now()
);

create table if not exists ops.jarvis_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);

alter table ops.jarvis_calls enable row level security;
alter table ops.jarvis_log enable row level security;
alter table ops.jarvis_settings enable row level security;

-- Call state: 'get' (creates the row), 'pin_ok', 'pin_bad', 'log', 'end'
create or replace function public.jarvis_call(p_call text, p_caller text, p_event text, p_data jsonb default '{}')
returns jsonb
language plpgsql security definer set search_path = ops, public
as $$
declare c ops.jarvis_calls;
begin
  insert into ops.jarvis_calls (call_id, caller) values (p_call, p_caller) on conflict (call_id) do nothing;
  if p_event = 'pin_ok' then
    update ops.jarvis_calls set verified_at = coalesce(verified_at, now()) where call_id = p_call;
  elsif p_event = 'pin_bad' then
    update ops.jarvis_calls set bad_pins = bad_pins + 1 where call_id = p_call;
  elsif p_event = 'log' then
    insert into ops.jarvis_log (call_id, tool, args, result)
      values (p_call, p_data ->> 'tool', p_data -> 'args', left(p_data ->> 'result', 4000));
  elsif p_event = 'end' then
    update ops.jarvis_calls set ended_at = now(), summary = p_data ->> 'summary', transcript = p_data ->> 'transcript'
      where call_id = p_call;
  end if;
  select * into c from ops.jarvis_calls where call_id = p_call;
  return jsonb_build_object('verified', c.verified_at is not null, 'bad_pins', c.bad_pins);
end $$;

create or replace function public.jarvis_setting(p_key text, p_value text default null)
returns text
language plpgsql security definer set search_path = ops, public
as $$
begin
  if p_value is not null then
    insert into ops.jarvis_settings (key, value) values (p_key, p_value)
      on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
  return (select value from ops.jarvis_settings where key = p_key);
end $$;

-- Everything waiting on Alex, numbered so it can be read out and decided by voice
create or replace function ops.jarvis_waiting()
returns table (n int, kind text, ref uuid, label text)
language sql stable security definer set search_path = ops, public
as $$
  select (row_number() over (order by at))::int, kind, ref, label from (
    select 'level' kind, r.id ref, r.created_at at,
           ops.who(r.farmer_id) || ' wants level ' || r.to_level || coalesce('. Their note: ' || left(r.note, 200), '') label
      from public.level_requests r where r.status = 'pending'
    union all
    select 'niche', p.id, p.niche_submitted_at, ops.who(p.id) || ' submitted their niche list: ' || left(coalesce(p.niche, ''), 200)
      from public.profiles p where p.niche_submitted_at is not null and p.niche_approved_at is null and p.niche_note is null
    union all
    select 'refund', r.id, r.created_at, ops.who(r.farmer_id) || ' sent a refund package' || coalesce('. Note: ' || left(r.note, 200), '')
      from public.refund_requests r where r.status = 'pending'
    union all
    select 'question', q.id, q.created_at, ops.who(q.farmer_id) || ' asked: ' || left(q.body, 250)
      from public.teacher_questions q where q.answer is null
    union all
    select 'payout', p.id, p.created_at, ops.who(p.recruiter_id) || ' is owed a ' || ops.money(p.amount) || ' recruiting bonus'
      from public.recruiter_payouts p where p.status = 'owed'
  ) x
$$;

-- The read and decide tools. Returns plain text Jarvis can say out loud.
create or replace function public.jarvis_tool(p_tool text, p_args jsonb default '{}')
returns text
language plpgsql security definer set search_path = ops, public
as $$
declare
  out text; w record; d ops.telegram_decisions; q text := btrim(coalesce(p_args ->> 'name', ''));
  yes boolean := coalesce((p_args ->> 'approve')::boolean, false); note text := nullif(btrim(p_args ->> 'note'), '');
begin
  if p_tool = 'business_report' then
    return ops.weekly_report();
  elsif p_tool = 'idle_farmers' then
    return ops.idle_yesterday();
  elsif p_tool = 'waiting_on_me' then
    select string_agg(n || '. ' || label, E'\n' order by n) into out from ops.jarvis_waiting();
    return coalesce('Waiting on you:' || E'\n' || out, 'Nothing is waiting on you right now.');
  elsif p_tool = 'find_farmer' then
    if length(q) < 2 then return 'Say at least part of their name.'; end if;
    select string_agg(
        coalesce(nullif(btrim(p.full_name), ''), p.email) || ': ' || p.role
        || case when p.role = 'farmer' then ', level ' || coalesce(p.level, 0)
             || case when p.enrollment_paid then ', paid' || case when p.comp then ' (free account)' else '' end
                  || coalesce(' ' || (now()::date - p.enrolled_at::date) || ' days ago', '') else ', not paid' end
             || coalesce(', teacher ' || t.full_name, '') || coalesce(', niche ' || left(p.niche, 80), '') else '' end
        || coalesce(', phone ' || p.phone, '')
        || ', last active ' || coalesce(to_char(public.last_active(p.id) at time zone 'America/Chicago', 'Mon FMDD'), 'never')
        || ', contractors ' || (select count(*) from public.contractors c where c.farmer_id = p.id)
        || ', leads sent ' || (select count(*) from public.leads l where l.farmer_id = p.id and l.direction = 'outbound')
        || ', leads closed ' || (select count(*) from public.leads l where l.farmer_id = p.id and l.status = 'closed'),
        E'\n')
      into out
      from (select * from public.profiles where full_name ilike '%' || q || '%' or email ilike '%' || q || '%' limit 5) p
      left join public.profiles t on t.id = p.teacher_id;
    return coalesce(out, 'Nobody matches "' || q || '".');
  elsif p_tool = 'send_text' then
    perform ops.telegram('📞 From your Jarvis call:' || E'\n' || left(coalesce(p_args ->> 'message', ''), 3500));
    return 'Sent to your Telegram.';
  elsif p_tool = 'decide' then
    select * into w from ops.jarvis_waiting() where n = (p_args ->> 'item')::int;
    if w.ref is null then return 'There is no item ' || coalesce(p_args ->> 'item', '?') || '. Ask what is waiting again.'; end if;
    if coalesce(btrim(p_args ->> 'who'), '') = '' or w.label not ilike '%' || btrim(p_args ->> 'who') || '%' then
      return 'Item ' || w.n || ' is not ' || coalesce(p_args ->> 'who', 'them') || '. It is: ' || w.label || '. Nothing changed.';
    end if;
    if w.kind = 'question' and note is null then return 'To answer a question, tell me the answer to send.'; end if;
    if w.kind = 'payout' and not yes then return 'Left that payout open.'; end if;
    select * into d from ops.telegram_decisions where kind = w.kind and ref = w.ref and decided_at is null order by id desc limit 1;
    if d.id is null then
      insert into ops.telegram_decisions (kind, ref) values (w.kind, w.ref) returning * into d;
    end if;
    out := ops.decide(d, yes, note);
    update ops.telegram_decisions set decided_at = now(),
      choice = case when w.kind = 'question' then 'answered' when yes then 'yes' else 'no' end || ' (phone)' where id = d.id;
    return coalesce(out, 'Done') || ': ' || w.label;
  end if;
  return 'Unknown tool ' || p_tool;
end $$;

revoke all on function public.jarvis_call(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.jarvis_setting(text, text) from public, anon, authenticated;
revoke all on function public.jarvis_tool(text, jsonb) from public, anon, authenticated;
revoke all on function ops.jarvis_waiting() from public, anon, authenticated;
grant execute on function public.jarvis_call(text, text, text, jsonb) to service_role;
grant execute on function public.jarvis_setting(text, text) to service_role;
grant execute on function public.jarvis_tool(text, jsonb) to service_role;

-- The key Vapi sends on every request (and the database uses for /setup). Generated here so nobody types it.
insert into ops.jarvis_settings (key, value) values ('secret', encode(extensions.gen_random_bytes(24), 'hex'))
  on conflict (key) do nothing;

-- Run once Alex's keys are saved: creates the Vapi assistant + phone number. Read the answer with
--   select status_code, content from net._http_response where id = <the id this returns>;
create or replace function ops.jarvis_setup(opts jsonb default '{}')
returns bigint
language sql security definer set search_path = ops, public
as $$
  select net.http_post(
    url := 'https://rkjsfuflfuckqyvaychm.supabase.co/functions/v1/jarvis/setup',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-jarvis-key', (select value from ops.jarvis_settings where key = 'secret')),
    body := opts,
    timeout_milliseconds := 30000)
$$;
revoke all on function ops.jarvis_setup(jsonb) from public, anon, authenticated;
