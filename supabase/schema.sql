-- Lead Farming farmer CRM: schema draft
-- Farmers (students) log in and track their own contractors/leads.
-- Admin (Alex) sees everything plus enrollment payments and recruiter payouts.

-- ---------- reference data ----------
create table public.stages (
  id smallint primary key,            -- 1..9
  name text not null,
  description text
);

insert into public.stages (id, name, description) values
 (1,'Contractor Identified','Business found, contact info known, no outreach yet'),
 (2,'Outreach Made','Introduced to the 15-25% referral arrangement'),
 (3,'Terms Agreed','Accepted referral fee terms; in active network'),
 (4,'First Lead Sent','At least one lead passed; relationship being tested'),
 (5,'First Lead Closed','Closed a job from your lead and paid the fee'),
 (6,'Reciprocal Active','Sending you leads outside their scope'),
 (7,'Anchor Status','You are a recurring revenue source; upsell trigger'),
 (8,'Upsell Pitched','Additional product/service pitched'),
 (9,'Upsell Closed','Purchased additional product/service');

create table public.trades (
  id serial primary key,
  name text not null unique,
  niche text not null default 'Home Services',
  sort_order int not null default 0
);

-- ---------- people ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  role text not null default 'farmer' check (role in ('farmer','admin')),
  recruited_by uuid references public.profiles(id),
  enrolled_at timestamptz,
  enrollment_fee numeric(10,2) not null default 500,
  enrollment_paid boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.recruiter_payouts (
  id uuid primary key default gen_random_uuid(),
  recruiter_id uuid not null references public.profiles(id),
  recruit_id uuid not null unique references public.profiles(id),
  amount numeric(10,2) not null default 250,
  status text not null default 'pending' check (status in ('pending','owed','paid','void')), -- owed once the recruit pays
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- farmer CRM ----------
create table public.contractors (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  trade_id int references public.trades(id),
  business_name text not null,
  contact_name text,
  phone text,
  email text,
  city text,
  found_via text,                      -- facebook, nextdoor, forum, other
  stage smallint not null default 1 references public.stages(id),
  fee_pct numeric(5,2) check (fee_pct between 0 and 100),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.contractor_stage_history (
  id bigserial primary key,
  contractor_id uuid not null references public.contractors(id) on delete cascade,
  from_stage smallint references public.stages(id),
  to_stage smallint not null references public.stages(id),
  changed_at timestamptz not null default now()
);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  contractor_id uuid references public.contractors(id) on delete set null,
  direction text not null default 'outbound' check (direction in ('outbound','inbound')), -- inbound = contractor sent it to you
  source text,                         -- nextdoor, facebook, contractor referral, other
  customer_name text,
  job_description text,
  status text not null default 'sent' check (status in ('new','sent','closed','lost')),
  job_value numeric(12,2),
  fee_pct numeric(5,2),
  fee_amount numeric(12,2) generated always as (round(job_value * fee_pct / 100, 2)) stored,
  fee_paid boolean not null default false,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create table public.upsells (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  contractor_id uuid not null references public.contractors(id) on delete cascade,
  product text not null,               -- AI tools, website refresh, marketing
  status text not null default 'pitched' check (status in ('pitched','closed','lost')),
  amount numeric(12,2),
  created_at timestamptz not null default now()
);

-- ---------- helpers & triggers ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- paid farmers (and admins) get the program; unpaid accounts only see their own profile + the Pay screen
create or replace function public.has_access() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and (enrollment_paid or role = 'admin'));
$$;
revoke execute on function public.has_access() from public, anon;
grant execute on function public.has_access() to authenticated;

create or replace function public.log_stage_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.stage is distinct from old.stage then
    insert into public.contractor_stage_history (contractor_id, from_stage, to_stage)
    values (new.id, case when tg_op = 'UPDATE' then old.stage end, new.stage);
  end if;
  new.updated_at := now();
  return new;
end $$;
-- AFTER for insert (needs row id present), BEFORE for update (sets updated_at)
create trigger contractors_stage_ins after insert on public.contractors
  for each row execute function public.log_stage_change();
create trigger contractors_stage_upd before update on public.contractors
  for each row execute function public.log_stage_change();

-- new auth user -> profile row
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare rec uuid;
begin
  select id into rec from public.profiles
   where lower(email) = lower(nullif(trim(new.raw_user_meta_data->>'recruiter_email'), ''));
  insert into public.profiles (id, email, full_name, phone, recruited_by)
  values (new.id, new.email, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone', rec);
  if rec is not null then
    insert into public.recruiter_payouts (recruiter_id, recruit_id) values (rec, new.id);
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- recruit pays enrollment -> recruiter payout becomes owed
create or replace function public.on_enrollment_paid() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.enrollment_paid and not old.enrollment_paid then
    new.enrolled_at := coalesce(new.enrolled_at, now());
    update public.recruiter_payouts set status = 'owed' where recruit_id = new.id and status = 'pending';
  end if;
  return new;
end $$;
create trigger profiles_enrollment_paid before update on public.profiles
  for each row execute function public.on_enrollment_paid();

-- ---------- RLS ----------
alter table public.stages enable row level security;
alter table public.trades enable row level security;
alter table public.profiles enable row level security;
alter table public.recruiter_payouts enable row level security;
alter table public.contractors enable row level security;
alter table public.contractor_stage_history enable row level security;
alter table public.leads enable row level security;
alter table public.upsells enable row level security;

create policy "read stages" on public.stages for select to authenticated using (public.has_access());
create policy "read trades" on public.trades for select to authenticated using (public.has_access());
create policy "admin trades" on public.trades for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "own profile read" on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "admin profile write" on public.profiles for all to authenticated using (public.is_admin()) with check (public.is_admin());
-- farmers may edit only their contact fields (role/payment columns locked via column grants below)
create policy "own profile update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant update (full_name, phone) on public.profiles to authenticated;

create policy "payouts read" on public.recruiter_payouts for select to authenticated using ((recruiter_id = auth.uid() and public.has_access()) or public.is_admin());
create policy "payouts admin" on public.recruiter_payouts for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "own contractors" on public.contractors for all to authenticated
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());
create policy "own history" on public.contractor_stage_history for select to authenticated
  using (exists (select 1 from public.contractors c where c.id = contractor_id and ((c.farmer_id = auth.uid() and public.has_access()) or public.is_admin())));
create policy "own leads" on public.leads for all to authenticated
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());
create policy "own upsells" on public.upsells for all to authenticated
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());

-- admin-only action (farmers can't touch payment columns directly)
create or replace function public.mark_enrollment_paid(farmer uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.profiles set enrollment_paid = true where id = farmer;
end $$;
revoke execute on function public.mark_enrollment_paid(uuid) from public, anon;
grant execute on function public.mark_enrollment_paid(uuid) to authenticated;

-- starter trades (edit in the Trades tab)
insert into public.trades (name, sort_order) values
 ('Plumbing',1),('Electrical',2),('HVAC',3),('Framing',4),('Drywall',5),('Concrete',6),('Painting',7),
 ('Roofing',8),('Flooring',9),('Landscaping',10),('Fencing',11),('Tile',12),('Cabinetry',13),('Siding & Gutters',14),('Handyman',15);

-- ---------- admin summary ----------
create view public.farmer_summary with (security_invoker = true) as
select p.id, p.full_name, p.email, p.enrollment_paid, p.recruited_by,
  (select count(*) from public.contractors c where c.farmer_id = p.id) as contractors,
  (select count(*) from public.contractors c where c.farmer_id = p.id and c.stage >= 3) as active_network,
  (select count(*) from public.leads l where l.farmer_id = p.id) as leads,
  (select count(*) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as leads_closed,
  (select coalesce(sum(fee_amount),0) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as fees_earned,
  (select count(*) from public.recruiter_payouts r where r.recruiter_id = p.id) as recruits
from public.profiles p where p.role = 'farmer';

create index on public.contractors (farmer_id, stage);
create index on public.leads (farmer_id, status);
create index on public.leads (contractor_id);

-- ---------- levels (migration 20261007_levels.sql; storage policies live in 20261007_proof_storage.sql) ----------
-- Levels: farmers move up by asking for the next level with proof; Alex or a verifier approves.
-- Level 1 opens automatically on payment. Locked levels only expose a vague teaser.

alter table public.profiles add column level smallint not null default 0 check (level between 0 and 3);
alter table public.profiles add column verifier boolean not null default false;  -- can review level-up requests

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
