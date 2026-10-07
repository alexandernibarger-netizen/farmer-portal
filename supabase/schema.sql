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
