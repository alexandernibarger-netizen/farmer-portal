-- Levels: farmers move up by asking for the next level with proof; Alex or a verifier approves.
-- Level 1 opens automatically on payment. Locked levels only expose a vague teaser.

alter table public.profiles add column level smallint not null default 0 check (level between 0 and 3);
alter table public.profiles add column verifier boolean not null default false;  -- can review level-up requests
-- (no paid farmers existed when this ran on 2026-10-07, so no level backfill was needed)

-- stages 1-3 open at level 1, 4-6 at level 2, 7-9 at level 3
alter table public.stages add column min_level smallint generated always as
  (case when id <= 3 then 1 when id <= 6 then 2 else 3 end) stored;

create table public.levels (
  level smallint primary key,
  name text not null,
  teaser text not null,          -- the only thing a farmer sees of a level two or more above theirs
  requirement text               -- what to finish on the level below before asking for this one
);
insert into public.levels (level, name, teaser, requirement) values
 (0,'Signed up','',null),
 (1,'Enrolled','Build your network',null),
 (2,'Network builder','Start earning referral fees','Get your first contractor to Terms Agreed (stage 3), then send proof, such as their signed referral-fee terms.'),
 (3,'Anchor and upsell','Grow your income further','Get a contractor to Reciprocal Active (stage 6), then send proof of a referral fee you received and a lead they sent you.');
alter table public.levels enable row level security;
create policy "admin levels" on public.levels for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.is_verifier() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and (verifier or role = 'admin'));
$$;
create or replace function public.my_level() returns smallint
language sql stable security definer set search_path = public as $$
  select case when role = 'admin' then 3::smallint else level end from public.profiles where id = auth.uid();
$$;
create or replace function public.has_access() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and (enrollment_paid or role = 'admin' or verifier));
$$;
create or replace function public.stage_ok(s smallint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.stages where id = s and min_level <= public.my_level());
$$;

-- The ladder as this farmer may see it: names and requirements only up to the next level
create or replace function public.level_ladder()
returns table (level smallint, name text, teaser text, requirement text)
language sql stable security definer set search_path = public as $$
  select l.level,
    case when l.level <= coalesce(public.my_level(), 0) + 1 then l.name end,
    l.teaser,
    case when l.level <= coalesce(public.my_level(), 0) + 1 then l.requirement end
  from public.levels l where public.has_access() order by l.level;
$$;

alter policy "read stages" on public.stages using (public.has_access() and min_level <= public.my_level());
alter policy "own contractors" on public.contractors
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access() and public.stage_ok(stage)) or public.is_admin());
alter policy "own leads" on public.leads
  using ((farmer_id = auth.uid() and public.has_access() and public.my_level() >= 2) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access() and public.my_level() >= 2) or public.is_admin());
alter policy "own upsells" on public.upsells
  using ((farmer_id = auth.uid() and public.has_access() and public.my_level() >= 3) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access() and public.my_level() >= 3) or public.is_admin());

-- payment opens level 1; a refund (paid -> unpaid) drops back to level 0
create or replace function public.on_enrollment_paid() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.enrollment_paid and not old.enrollment_paid then
    new.enrolled_at := coalesce(new.enrolled_at, now());
    new.level := greatest(new.level, 1);
    update public.recruiter_payouts set status = 'owed' where recruit_id = new.id and status = 'pending';
  elsif old.enrollment_paid and not new.enrollment_paid then
    new.level := 0;
  end if;
  return new;
end $$;

create table public.level_requests (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  to_level smallint not null check (to_level between 2 and 3),
  note text,
  files text[] not null default '{}',   -- paths in the private "proof" storage bucket
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewer_id uuid references public.profiles(id),
  review_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index level_requests_one_pending on public.level_requests (farmer_id) where status = 'pending';
alter table public.level_requests enable row level security;
-- reads only; every write goes through the functions below
create policy "requests read" on public.level_requests for select to authenticated
  using (farmer_id = auth.uid() or public.is_verifier());

create or replace function public.request_level_up(p_note text, p_files text[] default '{}') returns uuid
language plpgsql security definer set search_path = public as $$
declare lvl smallint; top smallint; rid uuid;
begin
  if not public.has_access() then raise exception 'Finish your enrollment first'; end if;
  select level into lvl from public.profiles where id = auth.uid();
  if lvl < 1 then raise exception 'Finish your enrollment first'; end if;
  if lvl >= 3 then raise exception 'You are already on the top level'; end if;
  select coalesce(max(stage), 0) into top from public.contractors where farmer_id = auth.uid();
  if (lvl = 1 and top < 3) or (lvl = 2 and top < 6) then
    raise exception 'Finish this level''s goal before asking for the next one';
  end if;
  if coalesce(btrim(p_note), '') = '' and coalesce(cardinality(p_files), 0) = 0 then
    raise exception 'Add a note or a file as proof';
  end if;
  if exists (select 1 from unnest(coalesce(p_files, '{}')) f where f not like auth.uid()::text || '/%') then
    raise exception 'Proof files must be your own uploads';
  end if;
  if exists (select 1 from public.level_requests where farmer_id = auth.uid() and status = 'pending') then
    raise exception 'Your request is already waiting for review';
  end if;
  insert into public.level_requests (farmer_id, to_level, note, files)
  values (auth.uid(), lvl + 1, nullif(btrim(p_note), ''), coalesce(p_files, '{}')) returning id into rid;
  return rid;
end $$;

create or replace function public.review_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, to_level smallint, note text, files text[], created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select r.id, r.farmer_id, p.full_name, p.email, r.to_level, r.note, r.files, r.created_at
    from public.level_requests r join public.profiles p on p.id = r.farmer_id
    where r.status = 'pending' order by r.created_at;
end $$;

create or replace function public.review_level_request(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.level_requests;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into r from public.level_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This request was already handled'; end if;
  if r.farmer_id = auth.uid() and not public.is_admin() then raise exception 'You can''t approve your own request'; end if;
  update public.level_requests set status = case when p_approve then 'approved' else 'rejected' end,
    reviewer_id = auth.uid(), review_note = nullif(btrim(p_note), ''), reviewed_at = now() where id = p_id;
  if p_approve then update public.profiles set level = greatest(level, r.to_level) where id = r.farmer_id; end if;
end $$;

-- admin-only: move a farmer by hand, or make someone a verifier
create or replace function public.set_level(farmer uuid, lvl smallint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.profiles set level = lvl where id = farmer;
end $$;
create or replace function public.set_verifier(farmer uuid, on_off boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.profiles set verifier = on_off where id = farmer;
end $$;

revoke execute on function public.is_verifier(), public.my_level(), public.stage_ok(smallint), public.level_ladder(),
  public.request_level_up(text, text[]), public.review_queue(), public.review_level_request(uuid, boolean, text),
  public.set_level(uuid, smallint), public.set_verifier(uuid, boolean) from public, anon;
grant execute on function public.is_verifier(), public.my_level(), public.stage_ok(smallint), public.level_ladder(),
  public.request_level_up(text, text[]), public.review_queue(), public.review_level_request(uuid, boolean, text),
  public.set_level(uuid, smallint), public.set_verifier(uuid, boolean) to authenticated;

create or replace view public.farmer_summary with (security_invoker = true) as
select p.id, p.full_name, p.email, p.enrollment_paid, p.recruited_by,
  (select count(*) from public.contractors c where c.farmer_id = p.id) as contractors,
  (select count(*) from public.contractors c where c.farmer_id = p.id and c.stage >= 3) as active_network,
  (select count(*) from public.leads l where l.farmer_id = p.id) as leads,
  (select count(*) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as leads_closed,
  (select coalesce(sum(fee_amount),0) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as fees_earned,
  (select count(*) from public.recruiter_payouts r where r.recruiter_id = p.id) as recruits,
  p.level, p.verifier
from public.profiles p where p.role = 'farmer';
