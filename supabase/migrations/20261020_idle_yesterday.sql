-- Telegram to Alex at 8am Texas time: paying farmers who logged nothing yesterday, with their number so he can text them.
-- "Logged" = the same sources as last_active(): contractors, leads, calls/comments, upsells, stage moves.
-- Free (comp) accounts are left out. pg_cron runs in UTC, so the job runs every hour and only sends at 8am Central.
create or replace function ops.idle_yesterday() returns text
language plpgsql stable security definer set search_path = public, ops as $$
declare
  d date := (now() at time zone 'America/Chicago')::date - 1;
  t0 timestamptz := d::timestamp at time zone 'America/Chicago';
  t1 timestamptz := (d + 1)::timestamp at time zone 'America/Chicago';
  total int; idle_n int; lines text;
begin
  select count(*) into total from profiles where role = 'farmer' and enrollment_paid and not comp;
  with idle as (
    select ops.who(p.id) name, p.phone, public.last_active(p.id) last, t.full_name teacher
    from profiles p left join profiles t on t.id = p.teacher_id
    where p.role = 'farmer' and p.enrollment_paid and not p.comp
      and not exists (select 1 from contractors c where c.farmer_id = p.id and c.created_at >= t0 and c.created_at < t1)
      and not exists (select 1 from leads l where l.farmer_id = p.id and l.created_at >= t0 and l.created_at < t1)
      and not exists (select 1 from activities a where a.farmer_id = p.id and a.created_at >= t0 and a.created_at < t1)
      and not exists (select 1 from upsells u where u.farmer_id = p.id and u.created_at >= t0 and u.created_at < t1)
      and not exists (select 1 from contractor_stage_history h join contractors c on c.id = h.contractor_id
                      where c.farmer_id = p.id and h.changed_at >= t0 and h.changed_at < t1))
  select count(*), string_agg('• ' || name || coalesce(' · ' || phone, '')
           || ' · ' || case when last is null then 'never logged anything'
                            else 'last active ' || to_char(last at time zone 'America/Chicago', 'Mon FMDD') end
           || coalesce(' · teacher ' || split_part(teacher, ' ', 1), ''), E'\n' order by last nulls first, name)
    into idle_n, lines
  from idle;
  if idle_n = 0 then
    return '✅ Everyone logged something yesterday (' || to_char(d, 'Dy Mon FMDD') || '). Nice.';
  end if;
  return '😴 Did nothing yesterday (' || to_char(d, 'Dy Mon FMDD') || '): ' || idle_n || ' of ' || total || ' paying farmers' || E'\n\n'
    || lines || E'\n\n' || 'Text them: "What''s your 10 for today?"' || E'\n' || 'https://leadfarminghq.com/app/';
end;
$$;
revoke execute on function ops.idle_yesterday() from public, anon, authenticated;

select cron.unschedule('telegram-idle-yesterday') where exists (select 1 from cron.job where jobname = 'telegram-idle-yesterday');
select cron.schedule('telegram-idle-yesterday', '0 * * * *',
  $$select ops.telegram(ops.idle_yesterday()) where extract(hour from now() at time zone 'America/Chicago') = 8$$);
