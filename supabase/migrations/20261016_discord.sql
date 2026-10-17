-- Lead Farming Discord (Alex, 2026-10-16): a server every paid farmer joins from the portal, with level roles kept in
-- step with the portal, portal alerts (behind on a quota, level approved, teacher check-ins...) mirrored to the
-- farmer's Discord DMs, a daily "behind board" for Alex and the teachers, and /progress in Discord.
-- All Discord calls go through the edge function `discord` (bot token there as a function secret). The database
-- reaches it with pg_net and a shared key in Supabase Vault (name discord_ops_key). Without that key nothing is sent.

-- ids Alex copies from Discord (application id, public key, server id) and the role/channel ids the bot creates.
-- None of these are secret, but only the edge function (service role) reads or writes them.
create table if not exists public.discord_config (key text primary key, value text not null);
alter table public.discord_config enable row level security;
revoke all on public.discord_config from anon, authenticated;

-- who is who: one Discord account per portal account
create table if not exists public.discord_links (
  farmer_id uuid primary key references public.profiles(id) on delete cascade,
  discord_id text not null unique,
  discord_name text,
  linked_at timestamptz not null default now());
alter table public.discord_links enable row level security;
drop policy if exists "own discord link" on public.discord_links;
create policy "own discord link" on public.discord_links for select to authenticated using (farmer_id = auth.uid() or public.is_admin());

-- one-time "state" values for the Discord sign-in, so the callback knows which portal account started it
create table if not exists public.discord_states (
  nonce text primary key,
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now());
alter table public.discord_states enable row level security;
revoke all on public.discord_states from anon, authenticated;

-- paid farmers, Alex and the teachers can join; unpaid sign-ups can't
create or replace function public.discord_eligible(f uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = f and (role = 'admin' or verifier or (role = 'farmer' and enrollment_paid)));
$$;

-- Settings/Home card: is Discord set up yet, and is this account linked?
create or replace function public.discord_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ready', exists (select 1 from public.discord_config where key = 'channel:general'),
    'eligible', public.discord_eligible(auth.uid()),
    'linked', (select discord_name from public.discord_links where farmer_id = auth.uid()),
    'server', (select 'https://discord.com/channels/' || g.value || '/' || c.value from public.discord_config g, public.discord_config c
               where g.key = 'guild_id' and c.key = 'channel:general'));
$$;
revoke execute on function public.discord_status() from public, anon;
grant execute on function public.discord_status() to authenticated;

-- the Discord sign-in link for the "Join the Discord" button
create or replace function public.discord_link_url() returns text
language plpgsql security definer set search_path = public as $$
declare cid text; n text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  if not public.discord_eligible(auth.uid()) then raise exception 'The Discord opens once your enrollment is paid'; end if;
  select value into cid from public.discord_config where key = 'client_id';
  if cid is null then raise exception 'The Discord isn''t set up yet'; end if;
  delete from public.discord_states where created_at < now() - interval '1 hour' or farmer_id = auth.uid();
  insert into public.discord_states (nonce, farmer_id) values (n, auth.uid());
  return 'https://discord.com/oauth2/authorize?response_type=code&scope=identify%20guilds.join&prompt=none'
    || '&client_id=' || cid
    || '&redirect_uri=' || replace(replace('https://rkjsfuflfuckqyvaychm.supabase.co/functions/v1/discord', ':', '%3A'), '/', '%2F')
    || '&state=' || n;
end $$;
revoke execute on function public.discord_link_url() from public, anon;
grant execute on function public.discord_link_url() to authenticated;

-- ---------- database -> Discord ----------
-- Fire and forget: queue one request to the edge function. Best effort, never blocks the caller.
create or replace function ops.discord(payload jsonb) returns void
language plpgsql security definer set search_path = ops, public as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'discord_ops_key';
  if k is null then return; end if;
  perform net.http_post(
    url := 'https://rkjsfuflfuckqyvaychm.supabase.co/functions/v1/discord',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-ops-key', k),
    body := payload, timeout_milliseconds := 10000);
exception when others then
  raise warning 'discord call failed: %', sqlerrm;
end $$;

-- the edge function checks the key the database sent against Vault
create or replace function public.discord_ops_ok(k text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(k, '') <> '' and exists (select 1 from vault.decrypted_secrets where name = 'discord_ops_key' and decrypted_secret = k);
$$;

-- what the bot needs to give someone the right roles and nickname
create or replace function public.discord_member(f uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('farmer_id', p.id, 'discord_id', l.discord_id,
    'name', coalesce(nullif(btrim(p.full_name), ''), split_part(p.email, '@', 1)),
    'farmer', p.role = 'farmer' and p.enrollment_paid,
    'level', case when p.role = 'farmer' and p.enrollment_paid then p.level else 0 end,
    'teacher', p.role = 'admin' or p.verifier,
    'admin', p.role = 'admin')
  from public.profiles p left join public.discord_links l on l.farmer_id = p.id where p.id = f;
$$;

-- /progress in Discord: the same 90-day numbers the portal shows
create or replace function public.discord_progress(did text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('farmer_id', l.farmer_id, 'name', coalesce(nullif(btrim(p.full_name), ''), p.email), 'level', p.level,
    'progress', public.refund_progress(l.farmer_id), 'reasons', public.stuck_reasons(l.farmer_id))
  from public.discord_links l join public.profiles p on p.id = l.farmer_id where l.discord_id = did;
$$;

revoke execute on function public.discord_ops_ok(text), public.discord_member(uuid), public.discord_progress(text), public.discord_eligible(uuid)
  from public, anon, authenticated;
grant execute on function public.discord_ops_ok(text), public.discord_member(uuid), public.discord_progress(text) to service_role;

-- level, payment, refund or teacher changes: re-sync that person's roles
create or replace function ops.on_discord_profile() returns trigger
language plpgsql security definer set search_path = ops, public as $$
begin
  if exists (select 1 from public.discord_links where farmer_id = new.id) then
    perform ops.discord(jsonb_build_object('action', 'sync', 'farmer_id', new.id));
  end if;
  return null;
end $$;
drop trigger if exists discord_sync on public.profiles;
create trigger discord_sync after update of level, enrollment_paid, verifier, role, full_name on public.profiles
  for each row when (old.level is distinct from new.level or old.enrollment_paid is distinct from new.enrollment_paid
    or old.verifier is distinct from new.verifier or old.role is distinct from new.role or old.full_name is distinct from new.full_name)
  execute function ops.on_discord_profile();

-- every portal alert also goes to the person's Discord DMs (behind on a quota, nothing logged, level approved, check-ins...)
create or replace function ops.on_discord_notification() returns trigger
language plpgsql security definer set search_path = ops, public as $$
begin
  if exists (select 1 from public.discord_links where farmer_id = new.farmer_id) then
    perform ops.discord(jsonb_build_object('action', 'dm', 'farmer_id', new.farmer_id, 'text', new.body));
  end if;
  return null;
end $$;
drop trigger if exists discord_dm on public.notifications;
create trigger discord_dm after insert on public.notifications for each row execute function ops.on_discord_notification();

-- Daily behind board for #behind-board (Alex and the teachers only): every stuck paid farmer, why, and their teacher
create or replace function ops.discord_board() returns void
language plpgsql security definer set search_path = ops, public as $$
declare rows jsonb;
begin
  select coalesce(jsonb_agg(x order by (x->>'day')::int desc), '[]') into rows from (
    select jsonb_build_object('name', coalesce(nullif(btrim(p.full_name), ''), p.email), 'discord_id', l.discord_id,
      'day', floor(extract(epoch from now() - p.enrolled_at) / 86400)::int,
      'reasons', (select jsonb_agg(r->>'text') from jsonb_array_elements(public.stuck_reasons(p.id)) r),
      'teacher', (select coalesce(nullif(btrim(t.full_name), ''), t.email) from public.profiles t where t.id = p.teacher_id),
      'teacher_discord', (select tl.discord_id from public.discord_links tl where tl.farmer_id = p.teacher_id)) x
    from public.profiles p left join public.discord_links l on l.farmer_id = p.id
    where p.role = 'farmer' and p.enrollment_paid and not p.comp) y
  where x->'reasons' is not null and x->'reasons' <> 'null'::jsonb;
  perform ops.discord(jsonb_build_object('action', 'board', 'farmers', rows));
end $$;

revoke execute on all functions in schema ops from public, anon, authenticated;

-- right after the daily nudges (15:00 UTC), so the board matches what farmers were just told
select cron.unschedule('discord-behind-board') where exists (select 1 from cron.job where jobname = 'discord-behind-board');
select cron.schedule('discord-behind-board', '10 15 * * *', $$select ops.discord_board()$$);
