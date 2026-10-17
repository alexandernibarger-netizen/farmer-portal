-- Discord, round 2 (Alex, 2026-10-17): milestone roles the portal hands out on its own (Contractor Signed, First Fee,
-- Recruiter, 90-Day Finisher, plus Founder for Alex), a shout-out in #wins on every level-up and milestone,
-- and a daily re-sync so nobody's roles drift. Channels and roles themselves are created by the edge function's setup.

-- what the bot needs to give someone the right roles and nickname (adds the milestones)
create or replace function public.discord_member(f uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('farmer_id', p.id, 'discord_id', l.discord_id,
    'name', coalesce(nullif(btrim(p.full_name), ''), split_part(p.email, '@', 1)),
    'farmer', p.role = 'farmer' and p.enrollment_paid,
    'level', case when p.role = 'farmer' and p.enrollment_paid then p.level else 0 end,
    'teacher', p.role = 'admin' or p.verifier,
    'admin', p.role = 'admin',
    'signed', exists (select 1 from public.contractors c where c.farmer_id = p.id and c.stage >= 3),
    'fee', exists (select 1 from public.leads d where d.farmer_id = p.id and d.fee_paid),
    'recruiter', exists (select 1 from public.recruiter_payouts r where r.recruiter_id = p.id and r.status in ('owed', 'paid')),
    'finisher', p.role = 'farmer' and p.enrollment_paid and coalesce((public.refund_progress(p.id)->>'all_met')::boolean, false))
  from public.profiles p left join public.discord_links l on l.farmer_id = p.id where p.id = f;
$$;
revoke execute on function public.discord_member(uuid) from public, anon, authenticated;
grant execute on function public.discord_member(uuid) to service_role;

-- level changes also get a shout-out in #wins when they go up
create or replace function ops.on_discord_profile() returns trigger
language plpgsql security definer set search_path = ops, public as $$
begin
  if exists (select 1 from public.discord_links where farmer_id = new.id) then
    perform ops.discord(jsonb_build_object('action', 'sync', 'farmer_id', new.id));
    if new.level > old.level and new.enrollment_paid then
      perform ops.discord(jsonb_build_object('action', 'levelup', 'farmer_id', new.id, 'level', new.level,
        'name', (select name from public.levels where level = new.level)));
    end if;
  end if;
  return null;
end $$;

-- milestones: a contractor reaching Terms Agreed, a fee marked paid, a recruit's bonus coming due
create or replace function ops.on_discord_milestone() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare f uuid;
begin
  if tg_table_name = 'contractor_stage_history' then
    if new.to_stage < 3 then return null; end if;
    select farmer_id into f from public.contractors where id = new.contractor_id;
  elsif tg_table_name = 'leads' then
    if not new.fee_paid or old.fee_paid then return null; end if;
    f := new.farmer_id;
  else
    if new.status not in ('owed', 'paid') or old.status in ('owed', 'paid') then return null; end if;
    f := new.recruiter_id;
  end if;
  if exists (select 1 from public.discord_links where farmer_id = f) then
    perform ops.discord(jsonb_build_object('action', 'sync', 'farmer_id', f));
  end if;
  return null;
end $$;
drop trigger if exists discord_milestone on public.contractor_stage_history;
create trigger discord_milestone after insert on public.contractor_stage_history for each row execute function ops.on_discord_milestone();
drop trigger if exists discord_milestone on public.leads;
create trigger discord_milestone after update of fee_paid on public.leads for each row execute function ops.on_discord_milestone();
drop trigger if exists discord_milestone on public.recruiter_payouts;
create trigger discord_milestone after update of status on public.recruiter_payouts for each row execute function ops.on_discord_milestone();

revoke execute on all functions in schema ops from public, anon, authenticated;

-- every day after the behind board, re-check everyone's roles (catches 90-Day Finisher and anything missed)
select cron.unschedule('discord-sync-all') where exists (select 1 from cron.job where jobname = 'discord-sync-all');
select cron.schedule('discord-sync-all', '20 15 * * *', $$select ops.discord('{"action":"sync_all"}'::jsonb)$$);
