-- Every Wednesday at 8pm Central: "meeting in 30 minutes" in #announcements, pinging everyone.
-- pg_cron runs in UTC, so the job fires at :00 every hour on Wed/Thu UTC and only posts when it's Wednesday 8pm in Chicago.
create or replace function ops.meeting_reminder() returns void
language plpgsql security definer set search_path = public, ops as $$
declare cfg_ch text;
begin
  if extract(dow from now() at time zone 'America/Chicago') <> 3 or extract(hour from now() at time zone 'America/Chicago') <> 20 then return; end if;
  select value into cfg_ch from discord_config where key = 'channel:weekly-meeting';
  perform ops.discord(jsonb_build_object('action', 'announce', 'channel', 'announcements', 'everyone', true, 'text',
    '@everyone ⏰ **Weekly meeting in 30 minutes** (8:30pm Central) in ' || coalesce('<#' || cfg_ch || '>', 'Weekly Meeting') || '.' || E'\n'
    || 'Bring your numbers for the week and one question. See you there! 🌾'));
end;
$$;
revoke execute on function ops.meeting_reminder() from public, anon, authenticated;

select cron.unschedule('discord-meeting-reminder') where exists (select 1 from cron.job where jobname = 'discord-meeting-reminder');
select cron.schedule('discord-meeting-reminder', '0 * * * 3,4', $$select ops.meeting_reminder()$$);
