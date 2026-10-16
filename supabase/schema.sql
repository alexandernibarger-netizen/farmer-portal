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
  enrollment_fee numeric(10,2) not null default 499,
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
  p.level, p.verifier, p.enrollment_fee
from public.profiles p where p.role = 'farmer';

-- ---------- lessons + quizzes (rows seeded from project files curriculum/lessons/seed.sql, not in this repo) ----------
-- Lessons and must-ace quizzes. A farmer only receives the lessons and quizzes of levels they've reached.
-- Quiz answers never leave the database: submit_quiz grades on the server.
-- Acing a level's quiz is required before requesting the next level and before asking a teacher about it.

create table public.quizzes (
  key text primary key,            -- l1, l2, l3, rec
  level smallint not null,         -- the level that opens it
  name text not null,
  title text not null,
  sort smallint not null
);
create table public.lessons (
  id text primary key,             -- 1a, 2b, ... (matches the curriculum)
  quiz text not null references public.quizzes(key),
  sort smallint not null,
  data jsonb not null              -- step, title, metaphor, cards[], check{q,o[],a}, svg
);
create table public.quiz_questions (
  quiz text not null references public.quizzes(key),
  idx smallint not null,
  q text not null,
  options jsonb not null,
  answer smallint not null,
  lesson text not null,            -- lesson to review if missed
  primary key (quiz, idx)
);
create table public.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  quiz text not null references public.quizzes(key),
  score smallint not null,
  total smallint not null,
  created_at timestamptz not null default now()
);
create table public.quiz_passes (
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  quiz text not null references public.quizzes(key),
  passed_at timestamptz not null default now(),
  primary key (farmer_id, quiz)
);
create table public.teacher_questions (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  quiz text not null references public.quizzes(key),
  body text not null,
  answer text,
  answered_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);

alter table public.quizzes enable row level security;
alter table public.lessons enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_attempts enable row level security;
alter table public.quiz_passes enable row level security;
alter table public.teacher_questions enable row level security;

create policy "read quizzes" on public.quizzes for select to authenticated
  using (public.has_access() and level <= public.my_level());
create policy "read lessons" on public.lessons for select to authenticated
  using (public.has_access() and exists (select 1 from public.quizzes z where z.key = quiz and z.level <= public.my_level()));
create policy "admin questions" on public.quiz_questions for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "read attempts" on public.quiz_attempts for select to authenticated using (farmer_id = auth.uid() or public.is_verifier());
create policy "read passes" on public.quiz_passes for select to authenticated using (farmer_id = auth.uid() or public.is_verifier());
create policy "read teacher questions" on public.teacher_questions for select to authenticated using (farmer_id = auth.uid() or public.is_verifier());

-- Questions without answers, for a quiz this farmer has reached
create or replace function public.get_quiz(p_quiz text)
returns table (idx smallint, q text, options jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.quizzes z where z.key = p_quiz and public.has_access() and z.level <= public.my_level()) then
    raise exception 'This quiz isn''t open for you yet';
  end if;
  return query select x.idx, x.q, x.options from public.quiz_questions x where x.quiz = p_quiz order by x.idx;
end $$;

-- p_answers[i] is the chosen option index for question idx = i - 1. Every answer must be right to pass.
create or replace function public.submit_quiz(p_quiz text, p_answers smallint[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int; ok int; review text[];
begin
  if not exists (select 1 from public.quizzes z where z.key = p_quiz and public.has_access() and z.level <= public.my_level()) then
    raise exception 'This quiz isn''t open for you yet';
  end if;
  select count(*), count(*) filter (where p_answers[x.idx + 1] = x.answer),
         coalesce(array_agg(distinct x.lesson) filter (where p_answers[x.idx + 1] is distinct from x.answer), '{}')
    into n, ok, review from public.quiz_questions x where x.quiz = p_quiz;
  insert into public.quiz_attempts (farmer_id, quiz, score, total) values (auth.uid(), p_quiz, ok, n);
  if n > 0 and ok = n then
    insert into public.quiz_passes (farmer_id, quiz) values (auth.uid(), p_quiz) on conflict do nothing;
  end if;
  return jsonb_build_object('passed', n > 0 and ok = n, 'score', ok, 'total', n, 'review', to_jsonb(review));
end $$;

create or replace function public.quiz_passed(p_quiz text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.quiz_passes where farmer_id = auth.uid() and quiz = p_quiz);
$$;

create or replace function public.ask_teacher(p_quiz text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare qid uuid;
begin
  if coalesce(btrim(p_body), '') = '' then raise exception 'Write your question first'; end if;
  if not public.quiz_passed(p_quiz) then
    raise exception 'Ace this quiz first. Everything on it is in the lessons.';
  end if;
  insert into public.teacher_questions (farmer_id, quiz, body) values (auth.uid(), p_quiz, btrim(p_body)) returning id into qid;
  return qid;
end $$;

create or replace function public.question_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, quiz text, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select t.id, t.farmer_id, p.full_name, p.email, t.quiz, t.body, t.created_at
    from public.teacher_questions t join public.profiles p on p.id = t.farmer_id
    where t.answer is null order by t.created_at;
end $$;

create or replace function public.answer_question(p_id uuid, p_answer text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  if coalesce(btrim(p_answer), '') = '' then raise exception 'Write an answer first'; end if;
  update public.teacher_questions set answer = btrim(p_answer), answered_by = auth.uid(), answered_at = now() where id = p_id;
end $$;

-- Level-up requests now also need this level's quiz aced
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
  if not public.quiz_passed('l' || lvl) then
    raise exception 'Ace the Level % quiz before asking for the next level', lvl;
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

revoke execute on function public.get_quiz(text), public.submit_quiz(text, smallint[]), public.quiz_passed(text),
  public.ask_teacher(text, text), public.question_queue(), public.answer_question(uuid, text) from public, anon;
grant execute on function public.get_quiz(text), public.submit_quiz(text, smallint[]), public.quiz_passed(text),
  public.ask_teacher(text, text), public.question_queue(), public.answer_question(uuid, text) to authenticated;

-- ---------- 90-day refund program (migration 20261007_refund_program.sql) ----------
-- Day 0 = the day the enrollment is paid (profiles.enrolled_at). Every quota counts only what was logged in the
-- portal by its deadline, using server timestamps, so nothing can be backdated or bulk-entered at the end.

-- ---------- server-side timestamps ----------
alter table public.contractors add column source_link text;   -- the post/profile where the contractor was found
alter table public.leads add column fee_paid_at timestamptz;
alter table public.upsells add column closed_at timestamptz;

create or replace function public.stamp_times() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then return new; end if;              -- admins may correct records by hand
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
  end if;
  if tg_table_name = 'leads' then
    if new.status = 'closed' and (tg_op = 'INSERT' or old.status is distinct from 'closed') then new.closed_at := now();
    elsif new.status <> 'closed' then new.closed_at := null;
    elsif tg_op = 'UPDATE' then new.closed_at := old.closed_at; end if;
    if new.fee_paid and (tg_op = 'INSERT' or not old.fee_paid) then new.fee_paid_at := now();
    elsif not new.fee_paid then new.fee_paid_at := null;
    elsif tg_op = 'UPDATE' then new.fee_paid_at := old.fee_paid_at; end if;
  elsif tg_table_name = 'upsells' then
    if new.status = 'closed' and (tg_op = 'INSERT' or old.status is distinct from 'closed') then new.closed_at := now();
    elsif new.status <> 'closed' then new.closed_at := null;
    elsif tg_op = 'UPDATE' then new.closed_at := old.closed_at; end if;
  end if;
  return new;
end $$;
create trigger contractors_stamp before insert or update on public.contractors for each row execute function public.stamp_times();
create trigger leads_stamp before insert or update on public.leads for each row execute function public.stamp_times();
create trigger upsells_stamp before insert or update on public.upsells for each row execute function public.stamp_times();

-- ---------- activity log: calls and daily neighbor comments ----------
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  contractor_id uuid references public.contractors(id) on delete set null,
  kind text not null check (kind in ('call', 'comments')),
  outcome text check (outcome in ('agreed', 'not interested', 'no answer', 'call back')),
  text_sent boolean not null default false,  -- the 20% follow-up text, for calls that ended in a yes
  count int not null default 1 check (count between 1 and 1000),  -- comments posted, for kind = comments
  created_at timestamptz not null default now()
);
alter table public.activities enable row level security;
create policy "own activities" on public.activities for all to authenticated
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()
    and (contractor_id is null or exists (select 1 from public.contractors c where c.id = contractor_id and c.farmer_id = auth.uid())))
    or public.is_admin());
create policy "verifier reads activities" on public.activities for select to authenticated using (public.is_verifier());
create trigger activities_stamp before insert or update on public.activities for each row execute function public.stamp_times();

-- ---------- step 0: the farmer's 15 business models, approved by Alex or a verifier ----------
alter table public.profiles add column niche text;               -- one business model per line
alter table public.profiles add column niche_submitted_at timestamptz;
alter table public.profiles add column niche_approved_at timestamptz;
alter table public.profiles add column niche_note text;          -- reviewer's note when sent back

create or replace function public.submit_niche(p_list text) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.has_access() then raise exception 'Finish your enrollment first'; end if;
  select count(distinct lower(btrim(x))) into n from unnest(string_to_array(coalesce(p_list, ''), E'\n')) x where btrim(x) <> '';
  if n < 15 then raise exception 'List 15 different business models, one per line (you have %)', n; end if;
  if exists (select 1 from public.profiles where id = auth.uid() and niche_approved_at is not null) then
    raise exception 'Your 15 are already approved';
  end if;
  update public.profiles set niche = btrim(p_list), niche_submitted_at = now(), niche_note = null where id = auth.uid();
end $$;

create or replace function public.niche_queue()
returns table (id uuid, full_name text, email text, niche text, niche_submitted_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select p.id, p.full_name, p.email, p.niche, p.niche_submitted_at from public.profiles p
    where p.niche_submitted_at is not null and p.niche_approved_at is null and p.niche_note is null order by p.niche_submitted_at;
end $$;

create or replace function public.review_niche(p_farmer uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  if p_farmer = auth.uid() and not public.is_admin() then raise exception 'You can''t approve your own list'; end if;
  if p_approve then
    update public.profiles set niche_approved_at = now(), niche_note = null where id = p_farmer;
  else
    update public.profiles set niche_note = coalesce(nullif(btrim(p_note), ''), 'Sent back') where id = p_farmer;
  end if;
end $$;

-- ---------- quota progress ----------
-- One row per quota and rule. "by day N" = logged no later than N days after payment.
create or replace function public.refund_progress(p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f uuid := coalesce(p_farmer, auth.uid());
  p public.profiles;
  t0 timestamptz;
  d int;
  steps jsonb := '[]';
  v1 int; v2 int; v3 int; ok boolean;
  fees numeric := 0;
  bonuses numeric := 0;
begin
  if f <> auth.uid() and not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into p from public.profiles where id = f;
  if p.id is null or not p.enrollment_paid or p.enrolled_at is null then return jsonb_build_object('enrolled', false); end if;
  t0 := p.enrolled_at;
  d := floor(extract(epoch from now() - t0) / 86400)::int;

  -- 0: 15 business models approved by day 3
  ok := p.niche_approved_at is not null and p.niche_submitted_at <= t0 + interval '3 days';  -- sent in time; review may land later
  steps := steps || jsonb_build_object('n', 0, 'name', 'Niche + 15 trades', 'quota', '15 business models, approved', 'deadline', 3,
    'progress', case when p.niche_approved_at is not null then 'Approved' when p.niche_note is not null then 'Sent back' when p.niche_submitted_at is not null then 'Waiting for review' else 'Not sent yet' end, 'met', ok);

  -- 1: 300 contractors with phone + source link, 20 in each of 15 trades, by day 14
  select coalesce(sum(n), 0), count(*) filter (where n >= 20 and trade_id is not null) into v1, v2 from (
    select c.trade_id, count(*) n from public.contractors c
    where c.farmer_id = f and c.created_at <= t0 + interval '14 days' and coalesce(c.phone, '') <> '' and coalesce(c.source_link, '') <> ''
    group by c.trade_id) x;
  steps := steps || jsonb_build_object('n', 1, 'name', 'Contractor Identified', 'quota', '300 contractors (20 in each of 15 trades), with phone and source link', 'deadline', 14,
    'progress', v1 || ' of 300 · ' || v2 || ' of 15 trades at 20', 'met', v1 >= 300 and v2 >= 15);

  -- 2: 300 contractors called by day 21; every "agreed" call has the 20% text
  select count(*), count(*) filter (where said_yes and not texted) into v1, v2 from (
    select a.contractor_id, bool_or(a.outcome = 'agreed') said_yes, bool_or(a.text_sent) texted
    from public.activities a where a.farmer_id = f and a.kind = 'call' and a.contractor_id is not null
      and a.created_at <= t0 + interval '21 days' group by a.contractor_id) x;
  steps := steps || jsonb_build_object('n', 2, 'name', 'Outreach Made', 'quota', '300 calls, plus the 20% text to every yes', 'deadline', 21,
    'progress', v1 || ' of 300 called' || case when v2 > 0 then ' · ' || v2 || ' yes without the 20% text' else '' end, 'met', v1 >= 300 and v2 = 0);

  -- 3: 150 contractors at Terms Agreed (stage 3+), 10 in each of 15 trades, by day 45
  select coalesce(sum(n), 0), count(*) filter (where n >= 10 and trade_id is not null) into v1, v2 from (
    select c.trade_id, count(*) n from public.contractors c
    where c.farmer_id = f and exists (select 1 from public.contractor_stage_history h
      where h.contractor_id = c.id and h.to_stage >= 3 and h.changed_at <= t0 + interval '45 days')
    group by c.trade_id) x;
  steps := steps || jsonb_build_object('n', 3, 'name', 'Terms Agreed', 'quota', '150 agreed, 10 in each of 15 trades', 'deadline', 45,
    'progress', v1 || ' of 150 · ' || v2 || ' of 15 trades at 10', 'met', v1 >= 150 and v2 >= 15);

  -- 4: 50 comments a day on 5 days of every week from day 7 to day 90; 300 leads to 100+ contractors by day 75
  select count(*) filter (where good_days >= 5) into v3 from (
    select w, (select count(*) from (
        select date_trunc('day', a.created_at - t0) dd from public.activities a
        where a.farmer_id = f and a.kind = 'comments'
          and a.created_at >= t0 + make_interval(days => 7 + 7 * w) and a.created_at < t0 + make_interval(days => 14 + 7 * w)
        group by 1 having sum(a.count) >= 50) z) good_days
    from generate_series(0, 11) w) y;
  select count(*), count(distinct l.contractor_id) into v1, v2 from public.leads l
    where l.farmer_id = f and l.direction = 'outbound' and l.created_at <= t0 + interval '75 days';
  steps := steps || jsonb_build_object('n', 4, 'name', 'First Lead Sent', 'quota', '50 comments a day, 5 days a week (days 7 to 90); 300 leads to 100+ contractors by day 75', 'deadline', 75,
    'progress', v3 || ' of 12 comment weeks · ' || v1 || ' of 300 leads · ' || v2 || ' of 100 contractors', 'met', v3 >= 12 and v1 >= 300 and v2 >= 100);

  -- referral fees actually received by day 90 (fee_paid_at is stamped by the server when marked paid);
  -- the refund is the price they paid minus these and the recruiting bonuses below
  select coalesce(sum(l.fee_amount), 0) into fees from public.leads l
    where l.farmer_id = f and l.direction = 'outbound' and l.status = 'closed' and l.fee_paid and l.fee_paid_at <= t0 + interval '90 days';
  -- $250 recruiting bonuses paid to them by day 90 (Alex, 2026-10-08); a bonus taken back after its recruit's refund doesn't count
  select coalesce(sum(r.amount), 0) into bonuses from public.recruiter_payouts r
    where r.recruiter_id = f and r.status = 'paid' and r.paid_at <= t0 + interval '90 days' and r.clawback_at is null;

  -- rules: activity on 5 of every 7 days (13 weeks, days 0-90); quizzes for every level reached
  select count(*) filter (where days >= least(5, len)) into v1 from (
    select w, least(7, 91 - 7 * w) len, (select count(distinct floor(extract(epoch from x.t - t0) / 86400)) from (
        select created_at t from public.contractors where farmer_id = f
        union all select created_at from public.leads where farmer_id = f
        union all select created_at from public.activities where farmer_id = f
        union all select created_at from public.upsells where farmer_id = f
        union all select h.changed_at from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = f) x
      where x.t >= t0 + make_interval(days => 7 * w) and x.t < t0 + make_interval(days => least(7 * w + 7, 91))) days
    from generate_series(0, 12) w) y;
  select count(distinct q.quiz) into v2 from public.quiz_passes q where q.farmer_id = f
    and q.quiz in (select 'l' || g from generate_series(1, greatest(p.level, 1)) g);

  return jsonb_build_object(
    'enrolled', true, 'paid_at', t0, 'day', d,
    'end_at', t0 + interval '90 days', 'submit_by', t0 + interval '97 days',
    'steps', steps,
    'rules', jsonb_build_array(
      jsonb_build_object('name', 'Portal activity on 5 of every 7 days', 'progress', v1 || ' of 13 weeks', 'met', v1 >= 13),
      jsonb_build_object('name', 'Quizzes aced for every level reached', 'progress', v2 || ' of ' || greatest(p.level, 1), 'met', v2 >= greatest(p.level, 1))),
    'all_met', not exists (select 1 from jsonb_array_elements(steps) s where not (s->>'met')::boolean) and v1 >= 13 and v2 >= greatest(p.level, 1),
    'price', p.enrollment_fee, 'fees', fees, 'bonuses', bonuses, 'refund_amount', greatest(0, p.enrollment_fee - fees - bonuses),
    'niche', p.niche, 'niche_note', p.niche_note,
    'comments_today', (select coalesce(sum(a.count), 0) from public.activities a
      where a.farmer_id = f and a.kind = 'comments' and a.created_at >= date_trunc('day', now())));
end $$;

-- ---------- the refund package ----------
create table public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  note text,
  files text[] not null default '{}',     -- evidence in the private "proof" bucket
  progress jsonb not null,                -- the quota check at the moment it was sent
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  reviewer_id uuid references public.profiles(id),
  review_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index refund_requests_one_open on public.refund_requests (farmer_id) where status in ('pending', 'approved');
alter table public.refund_requests enable row level security;
create policy "refund read" on public.refund_requests for select to authenticated using (farmer_id = auth.uid() or public.is_verifier());

create or replace function public.submit_refund_package(p_note text, p_files text[] default '{}') returns uuid
language plpgsql security definer set search_path = public as $$
declare pr jsonb; rid uuid;
begin
  pr := public.refund_progress(auth.uid());
  if not coalesce((pr->>'enrolled')::boolean, false) then raise exception 'Finish your enrollment first'; end if;
  if now() > (pr->>'submit_by')::timestamptz then raise exception 'The refund window closed on day 97'; end if;
  if not (pr->>'all_met')::boolean then raise exception 'Every quota has to be met before you can send the package'; end if;
  if (pr->>'refund_amount')::numeric <= 0 then raise exception 'Your referral fees and recruiting bonuses reached what you paid, so no refund is owed'; end if;
  if coalesce(cardinality(p_files), 0) = 0 then raise exception 'Attach your evidence files'; end if;
  if exists (select 1 from unnest(p_files) x where x not like auth.uid()::text || '/%') then
    raise exception 'Evidence files must be your own uploads';
  end if;
  if exists (select 1 from public.refund_requests where farmer_id = auth.uid() and status in ('pending', 'approved')) then
    raise exception 'Your refund package was already sent';
  end if;
  insert into public.refund_requests (farmer_id, note, files, progress)
  values (auth.uid(), nullif(btrim(p_note), ''), p_files, pr) returning id into rid;
  return rid;
end $$;

create or replace function public.refund_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, note text, files text[], progress jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select r.id, r.farmer_id, p.full_name, p.email, r.note, r.files, r.progress, r.created_at
    from public.refund_requests r join public.profiles p on p.id = r.farmer_id where r.status = 'pending' order by r.created_at;
end $$;

create or replace function public.review_refund(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.refund_requests;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into r from public.refund_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This package was already handled'; end if;
  if r.farmer_id = auth.uid() and not public.is_admin() then raise exception 'You can''t review your own package'; end if;
  update public.refund_requests set status = case when p_approve then 'approved' else 'denied' end,
    reviewer_id = auth.uid(), review_note = nullif(btrim(p_note), ''), reviewed_at = now() where id = p_id;
end $$;

-- Everything the package is checked against, straight from the CRM, for the reviewer's spot checks
create or replace function public.refund_evidence(p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f uuid := coalesce(p_farmer, auth.uid());
begin
  if f <> auth.uid() and not public.is_verifier() then raise exception 'verifiers only'; end if;
  return jsonb_build_object(
    'contractors', coalesce((select jsonb_agg(jsonb_build_object('business', c.business_name, 'contact', c.contact_name, 'phone', c.phone,
        'trade', t.name, 'stage', c.stage, 'source_link', c.source_link, 'logged', c.created_at) order by c.created_at)
      from public.contractors c left join public.trades t on t.id = c.trade_id where c.farmer_id = f), '[]'),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('business', c.business_name, 'phone', c.phone, 'outcome', a.outcome,
        'text_sent', a.text_sent, 'logged', a.created_at) order by a.created_at)
      from public.activities a left join public.contractors c on c.id = a.contractor_id where a.farmer_id = f and a.kind = 'call'), '[]'),
    'comments', coalesce((select jsonb_agg(jsonb_build_object('count', a.count, 'logged', a.created_at) order by a.created_at)
      from public.activities a where a.farmer_id = f and a.kind = 'comments'), '[]'),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('direction', l.direction, 'business', c.business_name, 'customer', l.customer_name,
        'job', l.job_description, 'status', l.status, 'job_value', l.job_value, 'fee', l.fee_amount, 'fee_paid', l.fee_paid,
        'logged', l.created_at, 'closed', l.closed_at, 'fee_paid_at', l.fee_paid_at) order by l.created_at)
      from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = f), '[]'),
    'upsells', coalesce((select jsonb_agg(jsonb_build_object('business', c.business_name, 'product', u.product, 'status', u.status,
        'amount', u.amount, 'logged', u.created_at, 'closed', u.closed_at) order by u.created_at)
      from public.upsells u join public.contractors c on c.id = u.contractor_id where u.farmer_id = f), '[]'));
end $$;

revoke execute on function public.refund_evidence(uuid) from public, anon;
grant execute on function public.refund_evidence(uuid) to authenticated;
revoke execute on function public.submit_niche(text), public.niche_queue(), public.review_niche(uuid, boolean, text),
  public.refund_progress(uuid), public.submit_refund_package(text, text[]), public.refund_queue(),
  public.review_refund(uuid, boolean, text), public.stamp_times() from public, anon;
revoke execute on function public.stamp_times() from authenticated;  -- trigger only
grant execute on function public.submit_niche(text), public.niche_queue(), public.review_niche(uuid, boolean, text),
  public.refund_progress(uuid), public.submit_refund_package(text, text[]), public.refund_queue(),
  public.review_refund(uuid, boolean, text) to authenticated;

-- ---------- follow-ups, clawbacks, waiting count (migration 20261007_followups.sql) ----------

-- ---------- referral clawback ----------
-- An approved refund cancels an unpaid $250; a $250 already paid is marked as owed back to the Company.
alter table public.recruiter_payouts add column clawback_at timestamptz;          -- recruit refunded after the $250 was paid
alter table public.recruiter_payouts add column clawback_settled_at timestamptz;  -- repaid or deducted

-- ---------- in-portal alerts to a farmer ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
alter table public.notifications enable row level security;
create policy "own notifications" on public.notifications for select to authenticated using (farmer_id = auth.uid());
create policy "dismiss own notifications" on public.notifications for update to authenticated
  using (farmer_id = auth.uid()) with check (farmer_id = auth.uid());
revoke insert, update, delete on public.notifications from authenticated, anon;
grant update (read_at) on public.notifications to authenticated;

-- Approving a refund now also claws back the recruiter's $250 and tells them why
create or replace function public.review_refund(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.refund_requests; po public.recruiter_payouts; who text;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into r from public.refund_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This package was already handled'; end if;
  if r.farmer_id = auth.uid() and not public.is_admin() then raise exception 'You can''t review your own package'; end if;
  update public.refund_requests set status = case when p_approve then 'approved' else 'denied' end,
    reviewer_id = auth.uid(), review_note = nullif(btrim(p_note), ''), reviewed_at = now() where id = p_id;
  if not p_approve then return; end if;
  select * into po from public.recruiter_payouts where recruit_id = r.farmer_id and status <> 'void' for update;
  if po.id is null then return; end if;
  select coalesce(nullif(btrim(full_name), ''), email) into who from public.profiles where id = r.farmer_id;
  if po.status = 'paid' then
    update public.recruiter_payouts set clawback_at = now() where id = po.id;
    insert into public.notifications (farmer_id, body) values (po.recruiter_id,
      who || ' got their enrollment refunded, so the $250 bonus you were paid for referring them is being clawed back. It comes out of your next bonus, or you repay it within 30 days.');
  else
    update public.recruiter_payouts set status = 'void' where id = po.id;
    insert into public.notifications (farmer_id, body) values (po.recruiter_id,
      who || ' got their enrollment refunded, so the $250 bonus for referring them is cancelled.');
  end if;
end $$;

-- The farmer's own referrals, with names (profiles are otherwise private)
create or replace function public.my_referrals()
returns table (full_name text, status text, amount numeric, created_at timestamptz, paid_at timestamptz, clawback_at timestamptz, clawback_settled_at timestamptz)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(p.full_name), ''), 'Your friend'), r.status, r.amount, r.created_at, r.paid_at, r.clawback_at, r.clawback_settled_at
  from public.recruiter_payouts r join public.profiles p on p.id = r.recruit_id
  where r.recruiter_id = auth.uid() and public.has_access() order by r.created_at desc;
$$;

-- How many things are waiting for a reviewer (the badge on the Approvals tab)
create or replace function public.waiting_count() returns int
language sql stable security definer set search_path = public as $$
  select case when not public.is_verifier() then 0 else (
    (select count(*) from public.level_requests where status = 'pending')
    + (select count(*) from public.teacher_questions where answer is null)
    + (select count(*) from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null)
    + (select count(*) from public.refund_requests where status = 'pending'))::int end;
$$;

revoke execute on function public.my_referrals(), public.waiting_count() from public, anon;
grant execute on function public.my_referrals(), public.waiting_count() to authenticated;

-- ---------- welcome-back greetings (migration 20261007_welcome.sql; starter lines below) ----------
create table public.welcome_lines (
  id serial primary key,
  body text not null check (length(btrim(body)) between 1 and 300),
  created_at timestamptz not null default now()
);
alter table public.welcome_lines enable row level security;
create policy "read welcome lines" on public.welcome_lines for select to authenticated using (public.has_access());
create policy "admin welcome lines" on public.welcome_lines for all to authenticated using (public.is_admin()) with check (public.is_admin());
insert into public.welcome_lines (body) values
 ('Welcome back, {name}. The crops didn''t plant themselves while you were gone.'),
 ('Look who''s back in the field! {name}, the contractors have been asking about you.'),
 ('Howdy, {name}. Grab your boots, it''s planting season.'),
 ('{name}! The early bird gets the worm, but the farmer gets the referral fee.'),
 ('Back again, {name}? Your pipeline missed you. It told us.'),
 ('Good to see you, {name}. Your network won''t water itself.'),
 ('Hey {name}, the scarecrow''s been holding down the fort. Your turn.'),
 ('{name} has entered the barn. Cows, look busy.'),
 ('Welcome back, {name}. Let''s turn some seeds into paychecks.'),
 ('Hey {name}! Somewhere out there a plumber is waiting for your call.'),
 ('Back in the saddle, {name}. Giddy up.'),
 ('{name}, you''re back! We kept the tractor warm for you.'),
 ('Welcome back, {name}. Fun fact: every harvest in history started with someone showing up.'),
 ('Rise and grind, {name}. Or just rise. We''ll take it.'),
 ('Well, well, well. If it isn''t {name}, finest farmer in the county.'),
 ('Welcome back, {name}. The chickens have been gossiping about your progress.'),
 ('{name}! Every contractor you call is a seed. Let''s plant a few.'),
 ('Hey {name}, the weeds didn''t pull themselves. Neither will those follow-ups.'),
 ('Welcome back, {name}. Today''s forecast: 100% chance of hustle.'),
 ('Look alive, {name}. Your 90-day clock is ticking like a rooster with a schedule.'),
 ('Hey {name}, ready to make it rain? The crops would appreciate it.'),
 ('Welcome back, {name}. The barn door was open, so we assumed you''d wander in.');

-- ---------- dashboard templates ----------
-- Each person picks a dashboard look in Settings. 'farm' is the default Duolingo-style look.
alter table public.profiles add column if not exists dashboard_template text not null default 'farm'
  check (dashboard_template in ('farm', 'clean', 'nightbarn', 'sunrise', 'almanac'));
grant update (dashboard_template) on public.profiles to authenticated;

-- ---------- terms acceptance (20261008_terms_acceptance.sql) ----------
alter table public.profiles add column if not exists terms_version text;
alter table public.profiles add column if not exists terms_accepted_at timestamptz;
create or replace function public.accept_terms(p_version text) returns void
language sql security definer set search_path = public as $$
  update public.profiles set terms_version = p_version, terms_accepted_at = now() where id = auth.uid();
$$;
revoke execute on function public.accept_terms(text) from public, anon;
grant execute on function public.accept_terms(text) to authenticated;

-- ---------- terms declined ----------
-- Paid farmers who turn down a new version of the Terms; Alex sees them in Approvals and handles the refund.
alter table public.profiles add column if not exists terms_declined_at timestamptz;
create or replace function public.decline_terms() returns void
language sql security definer set search_path = public as $$
  update public.profiles set terms_declined_at = now() where id = auth.uid();
$$;
revoke execute on function public.decline_terms() from public, anon;
grant execute on function public.decline_terms() to authenticated;

-- ---------- admin dashboard (20261008_admin_dashboard.sql) ----------
-- Everything Alex's Home screen shows, counted in the database so totals aren't cut off at the API's row limit.
create or replace function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'farmers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'level', p.level, 'verifier', p.verifier,
        'paid', p.enrollment_paid, 'fee', p.enrollment_fee, 'created_at', p.created_at, 'enrolled_at', p.enrolled_at,
        'terms_version', p.terms_version, 'terms_declined_at', p.terms_declined_at,
        'last_active', (select max(t) from (
            select max(created_at) t from public.contractors where farmer_id = p.id
            union all select max(created_at) from public.leads where farmer_id = p.id
            union all select max(created_at) from public.activities where farmer_id = p.id
            union all select max(created_at) from public.upsells where farmer_id = p.id
            union all select max(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = p.id) x),
        'progress', case when p.enrollment_paid and p.enrolled_at is not null then public.refund_progress(p.id) end)
      order by p.created_at) from public.profiles p where p.role = 'farmer'), '[]'),
    'work', jsonb_build_object(
      'contractors', (select count(*) from public.contractors),
      'agreed', (select count(*) from public.contractors where stage >= 3),
      'calls', (select count(*) from public.activities where kind = 'call'),
      'comments', (select coalesce(sum(count), 0) from public.activities where kind = 'comments'),
      'leads_sent', (select count(*) from public.leads where direction = 'outbound'),
      'leads_closed', (select count(*) from public.leads where status = 'closed'),
      'fees_earned', (select coalesce(sum(fee_amount), 0) from public.leads where status = 'closed'),
      'fees_collected', (select coalesce(sum(fee_amount), 0) from public.leads where status = 'closed' and fee_paid),
      'upsells_closed', (select count(*) from public.upsells where status = 'closed'),
      'upsell_revenue', (select coalesce(sum(amount), 0) from public.upsells where status = 'closed')),
    'money', jsonb_build_object(
      'bonuses_owed', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'owed'),
      'bonuses_pending', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'pending'),
      'bonuses_paid', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'paid' and clawback_at is null),
      'clawbacks_open', (select coalesce(sum(amount), 0) from public.recruiter_payouts where clawback_at is not null and clawback_settled_at is null),
      'refunds_approved', (select count(*) from public.refund_requests where status = 'approved'),
      'refunded', (select coalesce(sum((progress->>'refund_amount')::numeric), 0) from public.refund_requests where status = 'approved')),
    'waiting', jsonb_build_object(
      'level_ups', (select count(*) from public.level_requests where status = 'pending'),
      'questions', (select count(*) from public.teacher_questions where answer is null),
      'niches', (select count(*) from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null),
      'refunds', (select count(*) from public.refund_requests where status = 'pending')));
end $$;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;

-- First-login tour: the highest level whose portal tour the farmer has seen (0 = never toured)
alter table public.profiles add column if not exists tour_level smallint not null default 0;
grant update (tour_level) on public.profiles to authenticated;

-- Telegram alerts for Alex: dashboard events that need attention, plus a weekly stats summary.
-- The bot token and chat id live in Supabase Vault (names telegram_bot_token, telegram_chat_id),
-- added by hand, never in this file. With either missing, nothing is sent.
create extension if not exists pg_cron;
create schema if not exists ops;
revoke all on schema ops from public, anon, authenticated;

create or replace function ops.telegram(msg text) returns void
language plpgsql security definer set search_path = ops, public as $$
declare tok text; chat text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into chat from vault.decrypted_secrets where name = 'telegram_chat_id';
  if tok is null or chat is null or msg is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', left(msg, 4000), 'disable_web_page_preview', true));
end;
$$;

create or replace function ops.who(f uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(full_name), ''), email, 'A farmer') from public.profiles where id = f;
$$;

create or replace function ops.money(n numeric) returns text
language sql immutable as $$ select to_char(coalesce(n, 0), 'FM$999,999,990.00') $$;

-- One trigger function for every table we watch; each branch builds the alert text.
-- Alerts are best effort: a failure here must never block the farmer's action.
create or replace function ops.on_dashboard_event() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare msg text; lvl text;
begin
  begin
    if tg_table_name = 'profiles' then
      if tg_op = 'INSERT' and new.role = 'farmer' then
        msg := '👤 New signup: ' || coalesce(nullif(btrim(new.full_name), ''), new.email)
          || coalesce(' · ' || new.email, '') || E'\nThey still need to pay to unlock the portal.';
      elsif tg_op = 'UPDATE' then
        if new.niche_submitted_at is distinct from old.niche_submitted_at and new.niche_submitted_at is not null then
          msg := '🌱 Niche to review: ' || ops.who(new.id) || E'\n' || left(coalesce(new.niche, ''), 500);
        elsif new.terms_declined_at is distinct from old.terms_declined_at and new.terms_declined_at is not null then
          msg := '⚠️ ' || ops.who(new.id) || ' declined the enrollment terms.';
        end if;
      end if;
    elsif tg_table_name = 'level_requests' and tg_op = 'INSERT' then
      select name into lvl from public.levels where level = new.to_level;
      msg := '⬆️ Level-up request: ' || ops.who(new.farmer_id) || ' wants Level ' || new.to_level
        || coalesce(' (' || lvl || ')', '')
        || coalesce(E'\n"' || left(nullif(btrim(new.note), ''), 400) || '"', '')
        || coalesce(E'\n📎 ' || nullif(cardinality(new.files), 0) || ' proof file(s)', '');
    elsif tg_table_name = 'teacher_questions' and tg_op = 'INSERT' then
      select name into lvl from public.quizzes where key = new.quiz;
      msg := '❓ Question from ' || ops.who(new.farmer_id) || coalesce(' about the ' || lvl || ' quiz', '')
        || E':\n"' || left(new.body, 500) || '"';
    elsif tg_table_name = 'refund_requests' and tg_op = 'INSERT' then
      msg := '🔁 Refund package submitted by ' || ops.who(new.farmer_id) || '. Review it in Approvals.';
    elsif tg_table_name = 'recruiter_payouts' and tg_op = 'UPDATE'
          and new.status = 'owed' and old.status is distinct from 'owed' then
      msg := '💸 You owe ' || ops.money(new.amount) || ' to ' || ops.who(new.recruiter_id)
        || ' for recruiting ' || ops.who(new.recruit_id) || '.';
    end if;
    if msg is not null then
      perform ops.telegram(msg || E'\nhttps://leadfarminghq.com');
    end if;
  exception when others then
    raise warning 'telegram alert failed: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists telegram_alert on public.profiles;
create trigger telegram_alert after insert or update of niche_submitted_at, terms_declined_at on public.profiles
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.level_requests;
create trigger telegram_alert after insert on public.level_requests
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.teacher_questions;
create trigger telegram_alert after insert on public.teacher_questions
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.refund_requests;
create trigger telegram_alert after insert on public.refund_requests
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.recruiter_payouts;
create trigger telegram_alert after update of status on public.recruiter_payouts
  for each row execute function ops.on_dashboard_event();

-- Weekly summary of the 7 days before it runs, plus all-time totals and what is waiting on Alex.
create or replace function ops.weekly_report() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  t1 timestamptz := now(); t0 timestamptz := now() - interval '7 days';
  rev numeric; paid_n int; comm numeric; owed numeric; refunds int;
  rev_all numeric; comm_all numeric; farmers_all int;
  signups int; contractors_new int; contractors_all int;
  leads_sent int; leads_closed int; fees numeric; upsells_n int; upsells_amt numeric; levelups int;
  w_levels int; w_questions int; w_niches int; w_refunds int;
begin
  select count(*), sum(enrollment_fee) into paid_n, rev from public.profiles
    where enrollment_paid and enrolled_at >= t0 and enrolled_at < t1;
  select sum(amount) into comm from public.recruiter_payouts where status = 'paid' and paid_at >= t0 and paid_at < t1;
  select sum(amount) into owed from public.recruiter_payouts where status = 'owed';
  select count(*) into refunds from public.refund_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select sum(enrollment_fee), count(*) into rev_all, farmers_all from public.profiles where enrollment_paid and role = 'farmer';
  select sum(amount) into comm_all from public.recruiter_payouts where status = 'paid';
  select count(*) into signups from public.profiles where role = 'farmer' and created_at >= t0 and created_at < t1;
  select count(*) filter (where created_at >= t0 and created_at < t1), count(*) into contractors_new, contractors_all from public.contractors;
  select count(*) into leads_sent from public.leads where direction = 'outbound' and created_at >= t0 and created_at < t1;
  select count(*) into leads_closed from public.leads where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select sum(fee_amount) into fees from public.leads where fee_paid and fee_paid_at >= t0 and fee_paid_at < t1;
  select count(*), sum(amount) into upsells_n, upsells_amt from public.upsells where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select count(*) into levelups from public.level_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select count(*) into w_levels from public.level_requests where status = 'pending';
  select count(*) into w_questions from public.teacher_questions where answer is null;
  select count(*) into w_niches from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null;
  select count(*) into w_refunds from public.refund_requests where status = 'pending';

  return '📊 Weekly report: ' || to_char(t0 at time zone 'America/Chicago', 'Mon DD') || ' to '
    || to_char(t1 at time zone 'America/Chicago', 'Mon DD') || E'\n\n'
    || E'💰 Money (this week)\n'
    || 'Enrollments: ' || paid_n || ' paid, ' || ops.money(rev) || E' collected (before Stripe fees)\n'
    || 'Commissions paid out: ' || ops.money(comm) || E'\n'
    || 'Net: ' || ops.money(coalesce(rev, 0) - coalesce(comm, 0)) || E'\n'
    || 'Refunds approved: ' || refunds || E'\n'
    || 'Commissions still owed: ' || ops.money(owed) || E'\n\n'
    || E'📈 Growth (this week)\n'
    || 'New signups: ' || signups || E'\n'
    || 'New contractors added: ' || contractors_new || E'\n'
    || 'Leads sent: ' || leads_sent || ', closed: ' || leads_closed || E'\n'
    || 'Referral fees farmers collected: ' || ops.money(fees) || E'\n'
    || 'Upsells closed: ' || upsells_n || ' (' || ops.money(upsells_amt) || E')\n'
    || 'Level-ups approved: ' || levelups || E'\n\n'
    || E'🏦 All time\n'
    || 'Paid farmers: ' || farmers_all || E'\n'
    || 'Revenue: ' || ops.money(rev_all) || ', commissions paid: ' || ops.money(comm_all)
    || ', net: ' || ops.money(coalesce(rev_all, 0) - coalesce(comm_all, 0)) || E'\n'
    || 'Contractors in the system: ' || contractors_all || E'\n\n'
    || E'⏳ Waiting on you\n'
    || 'Level-up requests: ' || w_levels || ', questions: ' || w_questions
    || ', niches: ' || w_niches || ', refunds: ' || w_refunds || E'\n'
    || 'https://leadfarminghq.com';
end;
$$;

revoke execute on all functions in schema ops from public, anon, authenticated;

-- Mondays 13:00 UTC = 8am Central (7am in winter)
select cron.unschedule('telegram-weekly-report') where exists (select 1 from cron.job where jobname = 'telegram-weekly-report');
select cron.schedule('telegram-weekly-report', '0 13 * * 1', $$select ops.telegram(ops.weekly_report())$$);

-- ---------- farmer profiles: full history (20261012_farmer_history.sql) ----------

create table public.farmer_events (
  id bigint generated always as identity primary key,
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,          -- signed_up, paid, unpaid, terms_accepted, terms_declined, niche_submitted,
                               -- niche_approved, niche_sent_back, level_changed, verifier_on, verifier_off
  detail jsonb not null default '{}',
  actor_id uuid,               -- who made the change (null = the farmer themselves, Stripe, or unknown)
  created_at timestamptz not null default now()
);
create index farmer_events_farmer on public.farmer_events (farmer_id, created_at);
alter table public.farmer_events enable row level security;
create policy "admin reads events" on public.farmer_events for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.farmer_events from authenticated, anon;

create or replace function public.log_profile_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare who uuid := case when auth.uid() is distinct from new.id then auth.uid() end;
begin
  if tg_op = 'INSERT' then
    insert into public.farmer_events (farmer_id, kind, created_at) values (new.id, 'signed_up', new.created_at);
    return new;
  end if;
  if new.enrollment_paid and not old.enrollment_paid then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id) values (new.id, 'paid', jsonb_build_object('amount', new.enrollment_fee), who);
  elsif old.enrollment_paid and not new.enrollment_paid then
    insert into public.farmer_events (farmer_id, kind, actor_id) values (new.id, 'unpaid', who);
  end if;
  if new.terms_accepted_at is distinct from old.terms_accepted_at and new.terms_accepted_at is not null then
    insert into public.farmer_events (farmer_id, kind, detail) values (new.id, 'terms_accepted', jsonb_build_object('version', new.terms_version));
  end if;
  if new.terms_declined_at is distinct from old.terms_declined_at and new.terms_declined_at is not null then
    insert into public.farmer_events (farmer_id, kind) values (new.id, 'terms_declined');
  end if;
  if new.niche_submitted_at is distinct from old.niche_submitted_at and new.niche_submitted_at is not null then
    insert into public.farmer_events (farmer_id, kind, detail) values (new.id, 'niche_submitted', jsonb_build_object('list', new.niche));
  end if;
  if new.niche_approved_at is distinct from old.niche_approved_at and new.niche_approved_at is not null then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id) values (new.id, 'niche_approved', jsonb_build_object('list', new.niche), who);
  end if;
  if new.niche_note is distinct from old.niche_note and new.niche_note is not null then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id)
      values (new.id, 'niche_sent_back', jsonb_build_object('note', new.niche_note, 'list', new.niche), who);
  end if;
  if new.level is distinct from old.level then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id)
      values (new.id, 'level_changed', jsonb_build_object('from', old.level, 'to', new.level), who);
  end if;
  if new.verifier is distinct from old.verifier then
    insert into public.farmer_events (farmer_id, kind, actor_id) values (new.id, case when new.verifier then 'verifier_on' else 'verifier_off' end, who);
  end if;
  return new;
exception when others then
  return new;  -- the history is a record, never a reason to block the change itself
end $$;
revoke execute on function public.log_profile_events() from public, anon, authenticated;

create trigger profiles_history after insert or update on public.profiles
  for each row execute function public.log_profile_events();

-- Backfill from what the profiles show today (times the profile never kept are marked as such)
insert into public.farmer_events (farmer_id, kind, detail, created_at)
select id, 'signed_up', '{}', created_at from public.profiles
union all
select id, 'paid', jsonb_build_object('amount', enrollment_fee), enrolled_at from public.profiles where enrollment_paid and enrolled_at is not null
union all
select id, 'terms_accepted', jsonb_build_object('version', terms_version), terms_accepted_at from public.profiles where terms_accepted_at is not null
union all
select id, 'terms_declined', '{}', terms_declined_at from public.profiles where terms_declined_at is not null
union all
select id, 'niche_submitted', jsonb_build_object('list', niche), niche_submitted_at from public.profiles where niche_submitted_at is not null
union all
select id, 'niche_approved', jsonb_build_object('list', niche), niche_approved_at from public.profiles where niche_approved_at is not null
union all
select id, 'niche_sent_back', jsonb_build_object('note', niche_note, 'list', niche, 'time_unknown', true), niche_submitted_at
  from public.profiles where niche_note is not null and niche_submitted_at is not null;

-- One farmer's whole history, for their profile page. Admin only.
create or replace function public.farmer_history(p_farmer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare nm jsonb;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select coalesce(jsonb_object_agg(id, coalesce(nullif(btrim(full_name), ''), email)), '{}') into nm from public.profiles where role = 'admin' or verifier
    or id in (select recruit_id from public.recruiter_payouts where recruiter_id = p_farmer)
    or id = (select recruited_by from public.profiles where id = p_farmer);
  return jsonb_build_object(
    'names', nm,
    'profile', (select jsonb_build_object('niche', niche, 'niche_submitted_at', niche_submitted_at, 'niche_approved_at', niche_approved_at,
        'niche_note', niche_note, 'recruited_by', recruited_by, 'phone', phone, 'created_at', created_at) from public.profiles where id = p_farmer),
    'events', coalesce((select jsonb_agg(e order by e.at, e.ord, e.seq) from (
      select created_at at, 0 ord, id seq, kind, detail, actor_id actor from public.farmer_events where farmer_id = p_farmer
      union all
      select r.created_at, 1, 0, 'level_requested', jsonb_build_object('to', r.to_level, 'note', r.note, 'files', cardinality(r.files)), null
        from public.level_requests r where r.farmer_id = p_farmer
      union all
      select r.reviewed_at, 2, 0, 'level_' || r.status, jsonb_build_object('to', r.to_level, 'note', r.review_note), r.reviewer_id
        from public.level_requests r where r.farmer_id = p_farmer and r.reviewed_at is not null
      union all
      select t.created_at, 1, 0, 'question_asked', jsonb_build_object('quiz', q.name, 'body', t.body), null
        from public.teacher_questions t left join public.quizzes q on q.key = t.quiz where t.farmer_id = p_farmer
      union all
      select t.answered_at, 2, 0, 'question_answered', jsonb_build_object('quiz', q.name, 'body', t.body, 'answer', t.answer), t.answered_by
        from public.teacher_questions t left join public.quizzes q on q.key = t.quiz where t.farmer_id = p_farmer and t.answered_at is not null
      union all
      select a.created_at, 1, 0, 'quiz_taken', jsonb_build_object('quiz', q.name, 'score', a.score, 'total', a.total), null
        from public.quiz_attempts a left join public.quizzes q on q.key = a.quiz where a.farmer_id = p_farmer
      union all
      select r.created_at, 1, 0, 'refund_submitted', jsonb_build_object('note', r.note, 'files', cardinality(r.files)), null
        from public.refund_requests r where r.farmer_id = p_farmer
      union all
      select r.reviewed_at, 2, 0, 'refund_' || r.status, jsonb_build_object('note', r.review_note), r.reviewer_id
        from public.refund_requests r where r.farmer_id = p_farmer and r.reviewed_at is not null
      union all
      select p.created_at, 1, 0, 'referral_signed_up', jsonb_build_object('recruit', p.recruit_id, 'amount', p.amount, 'status', p.status), null
        from public.recruiter_payouts p where p.recruiter_id = p_farmer
      union all
      select p.paid_at, 2, 0, 'referral_paid_out', jsonb_build_object('recruit', p.recruit_id, 'amount', p.amount), null
        from public.recruiter_payouts p where p.recruiter_id = p_farmer and p.paid_at is not null
      union all
      select p.clawback_at, 3, 0, 'referral_clawback', jsonb_build_object('recruit', p.recruit_id, 'amount', p.amount, 'settled', p.clawback_settled_at is not null), null
        from public.recruiter_payouts p where p.recruiter_id = p_farmer and p.clawback_at is not null
      union all
      select l.created_at, 1, 0, 'lead_' || l.direction, jsonb_build_object('business', c.business_name, 'customer', l.customer_name, 'job', l.job_description), null
        from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = p_farmer
      union all
      select l.closed_at, 2, 0, 'lead_closed', jsonb_build_object('business', c.business_name, 'customer', l.customer_name, 'fee', l.fee_amount, 'direction', l.direction), null
        from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = p_farmer and l.closed_at is not null
      union all
      select l.fee_paid_at, 3, 0, 'fee_paid', jsonb_build_object('business', c.business_name, 'fee', l.fee_amount), null
        from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = p_farmer and l.fee_paid_at is not null
      union all
      select u.closed_at, 2, 0, 'upsell_closed', jsonb_build_object('business', c.business_name, 'product', u.product, 'amount', u.amount), null
        from public.upsells u left join public.contractors c on c.id = u.contractor_id where u.farmer_id = p_farmer and u.closed_at is not null
      union all  -- contractors and calls are many, so one line per day
      select min(created_at), 1, 0, 'contractors_added', jsonb_build_object('count', count(*)), null
        from public.contractors where farmer_id = p_farmer group by created_at::date
      union all
      select min(created_at), 1, 0, 'calls_logged', jsonb_build_object('count', count(*)), null
        from public.activities where farmer_id = p_farmer and kind = 'call' group by created_at::date
    ) e), '[]'));
end $$;
revoke execute on function public.farmer_history(uuid) from public, anon;
grant execute on function public.farmer_history(uuid) to authenticated;


-- My farmland: each farmer's 50-mile area map. towns[1] is the home base, then as many more towns as they farm (up to 50 in all).
-- Each contractor is tagged with one of the farmer's 15 niches; its city is the town it covers.
alter table public.profiles add column if not exists towns text[] not null default '{}'
  check (cardinality(towns) <= 10);
grant update (towns) on public.profiles to authenticated;
alter table public.contractors add column if not exists niche text;
-- Farmers can add more than 10 towns (raised from 10 on 2026-10-13).
alter table public.profiles drop constraint if exists profiles_towns_check;
alter table public.profiles add constraint profiles_towns_check check (cardinality(towns) <= 50);

-- ---------- comp accounts and non-cash bonuses (20261014_comp_accounts.sql) ----------
alter table public.profiles add column if not exists comp boolean not null default false;
alter table public.recruiter_payouts add column if not exists not_cash boolean not null default false;

create or replace function public.set_comp(farmer uuid, on_off boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.profiles set comp = on_off where id = farmer;
end $$;
revoke execute on function public.set_comp(uuid, boolean) from public, anon;
grant execute on function public.set_comp(uuid, boolean) to authenticated;

create or replace view public.farmer_summary with (security_invoker = true) as
select p.id, p.full_name, p.email, p.enrollment_paid, p.recruited_by,
  (select count(*) from public.contractors c where c.farmer_id = p.id) as contractors,
  (select count(*) from public.contractors c where c.farmer_id = p.id and c.stage >= 3) as active_network,
  (select count(*) from public.leads l where l.farmer_id = p.id) as leads,
  (select count(*) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as leads_closed,
  (select coalesce(sum(fee_amount),0) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as fees_earned,
  (select count(*) from public.recruiter_payouts r where r.recruiter_id = p.id) as recruits,
  p.level, p.verifier, p.enrollment_fee, p.comp
from public.profiles p where p.role = 'farmer';

-- Same dashboard as before, plus each farmer's comp flag; bonuses paid leave out the ones never paid in cash.
create or replace function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'farmers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'level', p.level, 'verifier', p.verifier,
        'paid', p.enrollment_paid, 'fee', p.enrollment_fee, 'comp', p.comp, 'created_at', p.created_at, 'enrolled_at', p.enrolled_at,
        'terms_version', p.terms_version, 'terms_declined_at', p.terms_declined_at,
        'last_active', (select max(t) from (
            select max(created_at) t from public.contractors where farmer_id = p.id
            union all select max(created_at) from public.leads where farmer_id = p.id
            union all select max(created_at) from public.activities where farmer_id = p.id
            union all select max(created_at) from public.upsells where farmer_id = p.id
            union all select max(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = p.id) x),
        'progress', case when p.enrollment_paid and p.enrolled_at is not null then public.refund_progress(p.id) end)
      order by p.created_at) from public.profiles p where p.role = 'farmer'), '[]'),
    'work', jsonb_build_object(
      'contractors', (select count(*) from public.contractors),
      'agreed', (select count(*) from public.contractors where stage >= 3),
      'calls', (select count(*) from public.activities where kind = 'call'),
      'comments', (select coalesce(sum(count), 0) from public.activities where kind = 'comments'),
      'leads_sent', (select count(*) from public.leads where direction = 'outbound'),
      'leads_closed', (select count(*) from public.leads where status = 'closed'),
      'fees_earned', (select coalesce(sum(fee_amount), 0) from public.leads where status = 'closed'),
      'fees_collected', (select coalesce(sum(fee_amount), 0) from public.leads where status = 'closed' and fee_paid),
      'upsells_closed', (select count(*) from public.upsells where status = 'closed'),
      'upsell_revenue', (select coalesce(sum(amount), 0) from public.upsells where status = 'closed')),
    'money', jsonb_build_object(
      'bonuses_owed', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'owed'),
      'bonuses_pending', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'pending'),
      'bonuses_paid', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'paid' and clawback_at is null and not not_cash),
      'bonuses_not_cash', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'paid' and not_cash),
      'clawbacks_open', (select coalesce(sum(amount), 0) from public.recruiter_payouts where clawback_at is not null and clawback_settled_at is null),
      'refunds_approved', (select count(*) from public.refund_requests where status = 'approved'),
      'refunded', (select coalesce(sum((progress->>'refund_amount')::numeric), 0) from public.refund_requests where status = 'approved')),
    'waiting', jsonb_build_object(
      'level_ups', (select count(*) from public.level_requests where status = 'pending'),
      'questions', (select count(*) from public.teacher_questions where answer is null),
      'niches', (select count(*) from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null),
      'refunds', (select count(*) from public.refund_requests where status = 'pending')));
end $$;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;

-- Monday report: comp accounts aren't revenue, and bonuses never paid in cash aren't commissions paid.
create or replace function ops.weekly_report() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  t1 timestamptz := now(); t0 timestamptz := now() - interval '7 days';
  rev numeric; paid_n int; comm numeric; owed numeric; refunds int;
  rev_all numeric; comm_all numeric; farmers_all int;
  signups int; contractors_new int; contractors_all int;
  leads_sent int; leads_closed int; fees numeric; upsells_n int; upsells_amt numeric; levelups int;
  w_levels int; w_questions int; w_niches int; w_refunds int;
begin
  select count(*), sum(enrollment_fee) into paid_n, rev from public.profiles
    where enrollment_paid and not comp and enrolled_at >= t0 and enrolled_at < t1;
  select sum(amount) into comm from public.recruiter_payouts where status = 'paid' and not not_cash and paid_at >= t0 and paid_at < t1;
  select sum(amount) into owed from public.recruiter_payouts where status = 'owed';
  select count(*) into refunds from public.refund_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select sum(enrollment_fee), count(*) into rev_all, farmers_all from public.profiles where enrollment_paid and not comp and role = 'farmer';
  select sum(amount) into comm_all from public.recruiter_payouts where status = 'paid' and not not_cash;
  select count(*) into signups from public.profiles where role = 'farmer' and created_at >= t0 and created_at < t1;
  select count(*) filter (where created_at >= t0 and created_at < t1), count(*) into contractors_new, contractors_all from public.contractors;
  select count(*) into leads_sent from public.leads where direction = 'outbound' and created_at >= t0 and created_at < t1;
  select count(*) into leads_closed from public.leads where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select sum(fee_amount) into fees from public.leads where fee_paid and fee_paid_at >= t0 and fee_paid_at < t1;
  select count(*), sum(amount) into upsells_n, upsells_amt from public.upsells where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select count(*) into levelups from public.level_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select count(*) into w_levels from public.level_requests where status = 'pending';
  select count(*) into w_questions from public.teacher_questions where answer is null;
  select count(*) into w_niches from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null;
  select count(*) into w_refunds from public.refund_requests where status = 'pending';

  return '📊 Weekly report: ' || to_char(t0 at time zone 'America/Chicago', 'Mon DD') || ' to '
    || to_char(t1 at time zone 'America/Chicago', 'Mon DD') || E'\n\n'
    || E'💰 Money (this week)\n'
    || 'Enrollments: ' || paid_n || ' paid, ' || ops.money(rev) || E' collected (before Stripe fees)\n'
    || 'Commissions paid out: ' || ops.money(comm) || E'\n'
    || 'Net: ' || ops.money(coalesce(rev, 0) - coalesce(comm, 0)) || E'\n'
    || 'Refunds approved: ' || refunds || E'\n'
    || 'Commissions still owed: ' || ops.money(owed) || E'\n\n'
    || E'📈 Growth (this week)\n'
    || 'New signups: ' || signups || E'\n'
    || 'New contractors added: ' || contractors_new || E'\n'
    || 'Leads sent: ' || leads_sent || ', closed: ' || leads_closed || E'\n'
    || 'Referral fees farmers collected: ' || ops.money(fees) || E'\n'
    || 'Upsells closed: ' || upsells_n || ' (' || ops.money(upsells_amt) || E')\n'
    || 'Level-ups approved: ' || levelups || E'\n\n'
    || E'🏦 All time\n'
    || 'Paid farmers: ' || farmers_all || E'\n'
    || 'Revenue: ' || ops.money(rev_all) || ', commissions paid: ' || ops.money(comm_all)
    || ', net: ' || ops.money(coalesce(rev_all, 0) - coalesce(comm_all, 0)) || E'\n'
    || 'Contractors in the system: ' || contractors_all || E'\n\n'
    || E'⏳ Waiting on you\n'
    || 'Level-up requests: ' || w_levels || ', questions: ' || w_questions
    || ', niches: ' || w_niches || ', refunds: ' || w_refunds || E'\n'
    || 'https://leadfarminghq.com';
end;
$$;
revoke execute on function ops.weekly_report() from public, anon, authenticated;

-- ---------- activation nudges, teachers, weekly progress email (20261014_activation_nudges.sql) ----------
-- Activation nudges (Alex, 2026-10-14): find paid farmers who are stuck, alert them in the portal and by email,
-- let Alex hand each one to a teacher, and send every farmer a weekly progress email.
-- Emails go through Resend's API with the key in Supabase Vault (name resend_api_key, added by hand).
-- Without the key, the in-portal alerts still go out and no email is sent.
-- Resend's free plan allows 100 emails a day, shared with sign-up and password emails, so these use at most
-- ops.email_cap() a day (60) and the rest is left for those.

-- the teacher (Alex or a verifier) checking in on a farmer
alter table public.profiles add column if not exists teacher_id uuid references public.profiles(id) on delete set null;

-- every nudge sent, so the same one isn't repeated and the daily email cap can be counted
create table if not exists public.nudges (
  id bigint generated always as identity primary key,
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('no_contractors', 'inactive', 'behind', 'weekly')),
  detail text,
  emailed boolean not null default false,
  created_at timestamptz not null default now());
create index if not exists nudges_farmer_kind on public.nudges (farmer_id, kind, created_at desc);
alter table public.nudges enable row level security;
create policy "nudges admin read" on public.nudges for select using (public.is_admin());

-- the last time a farmer logged anything (same sources as the dashboard's "last active")
create or replace function public.last_active(f uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(t) from (
    select max(created_at) t from public.contractors where farmer_id = f
    union all select max(created_at) from public.leads where farmer_id = f
    union all select max(created_at) from public.activities where farmer_id = f
    union all select max(created_at) from public.upsells where farmer_id = f
    union all select max(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = f) x;
$$;
revoke execute on function public.last_active(uuid) from public, anon, authenticated;

-- Why a paid farmer is stuck: no contractors 48 hours after paying, nothing logged for 3 days,
-- or a 90-day quota whose date has passed. Free (comp) accounts and finished programs are left out.
create or replace function public.stuck_reasons(f uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles; pr jsonb; r jsonb := '[]'; la timestamptz; s jsonb;
begin
  select * into p from public.profiles where id = f;
  if p.id is null or p.role <> 'farmer' or not p.enrollment_paid or p.comp or p.enrolled_at is null
     or p.enrolled_at < now() - interval '90 days' then return r; end if;
  if p.enrolled_at < now() - interval '48 hours' and not exists (select 1 from public.contractors where farmer_id = f) then
    r := r || jsonb_build_object('kind', 'no_contractors', 'key', 'no_contractors', 'text', 'No contractors added since paying');
  end if;
  la := coalesce(public.last_active(f), p.enrolled_at);
  if la < now() - interval '3 days' then
    r := r || jsonb_build_object('kind', 'inactive', 'key', 'inactive', 'text', 'Nothing logged for ' || floor(extract(epoch from now() - la) / 86400)::int || ' days');
  end if;
  pr := public.refund_progress(f);
  for s in select * from jsonb_array_elements(coalesce(pr->'steps', '[]')) loop
    if not (s->>'met')::boolean and (s->>'deadline')::int < (pr->>'day')::int then
      r := r || jsonb_build_object('kind', 'behind', 'key', 'behind:' || (s->>'n'), 'step', (s->>'n')::int,
        'text', 'Behind on step ' || (s->>'n') || ', ' || (s->>'name') || ' (due day ' || (s->>'deadline') || ', at ' || (s->>'progress') || ')');
    end if;
  end loop;
  return r;
end $$;
revoke execute on function public.stuck_reasons(uuid) from public, anon, authenticated;

-- Admin Home: the stuck list, plus who can be assigned as a teacher (Alex and the verifiers)
create or replace function public.stuck_farmers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'farmers', coalesce((select jsonb_agg(x order by x->>'full_name') from (
      select jsonb_build_object('id', p.id, 'full_name', coalesce(nullif(btrim(p.full_name), ''), p.email), 'email', p.email, 'phone', p.phone,
        'day', floor(extract(epoch from now() - p.enrolled_at) / 86400)::int, 'reasons', public.stuck_reasons(p.id),
        'last_active', public.last_active(p.id), 'teacher_id', p.teacher_id,
        'last_nudge', (select max(n.created_at) from public.nudges n where n.farmer_id = p.id and n.kind <> 'weekly')) x
      from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp) y
      where jsonb_array_length(x->'reasons') > 0), '[]'),
    'teachers', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'full_name', coalesce(nullif(btrim(t.full_name), ''), t.email)) order by t.role <> 'admin', t.full_name)
      from public.profiles t where t.role = 'admin' or t.verifier), '[]'));
end $$;
revoke execute on function public.stuck_farmers() from public, anon;
grant execute on function public.stuck_farmers() to authenticated;

-- Hand a farmer to a teacher; the teacher (if it isn't Alex) gets an alert in the portal
create or replace function public.assign_teacher(farmer uuid, teacher uuid) returns void
language plpgsql security definer set search_path = public as $$
declare why text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if teacher is not null and not exists (select 1 from public.profiles where id = teacher and (role = 'admin' or verifier)) then
    raise exception 'Only Alex or a verifier can be a teacher';
  end if;
  update public.profiles set teacher_id = teacher where id = farmer;
  if teacher is not null and teacher is distinct from auth.uid() then
    select string_agg(r->>'text', '; ') into why from jsonb_array_elements(public.stuck_reasons(farmer)) r;
    insert into public.notifications (farmer_id, body) select teacher,
      'Alex asked you to check in with ' || coalesce(nullif(btrim(full_name), ''), email) || coalesce(' (' || phone || ')', '')
      || coalesce('. ' || why || '.', '.') || ' They are under "Farmers to check in on" on your Home.'
      from public.profiles where id = farmer;
  end if;
end $$;
revoke execute on function public.assign_teacher(uuid, uuid) from public, anon;
grant execute on function public.assign_teacher(uuid, uuid) to authenticated;

-- A teacher's own list of farmers to check in on
create or replace function public.my_students() returns table (full_name text, email text, phone text, day int, reasons jsonb, last_active timestamptz)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(p.full_name), ''), p.email), p.email, p.phone,
    floor(extract(epoch from now() - p.enrolled_at) / 86400)::int, public.stuck_reasons(p.id), public.last_active(p.id)
  from public.profiles p where p.teacher_id = auth.uid() and p.enrollment_paid and public.is_verifier()
  order by p.full_name;
$$;
revoke execute on function public.my_students() from public, anon;
grant execute on function public.my_students() to authenticated;

-- ---------- email ----------
create or replace function ops.email_cap() returns int language sql immutable as 'select 60';
create or replace function ops.emails_today() returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.nudges where emailed and created_at >= date_trunc('day', now());
$$;

-- Sends one email through Resend. Returns false (and sends nothing) without the Vault key.
create or replace function ops.send_email(to_addr text, subject text, html text) returns boolean
language plpgsql security definer set search_path = ops, public as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key';
  if k is null or coalesce(to_addr, '') = '' then return false; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object('from', 'Lead Farming HQ <noreply@leadfarminghq.com>', 'to', jsonb_build_array(to_addr),
      'reply_to', 'support@leadfarminghq.com', 'subject', subject, 'html', html));
  return true;
end $$;

-- the same layout for every email: greeting, body paragraphs, one button to the portal
create or replace function ops.email_html(first text, paras text[]) returns text
language sql immutable as $$
  select '<div style="font-family:Arial,sans-serif;font-size:16px;line-height:1.5;color:#2B3A2E;max-width:560px">'
    || '<p>Hi ' || coalesce(nullif(replace(replace(replace(first, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), ''), 'there') || ',</p>'
    || (select string_agg('<p>' || x || '</p>', '') from unnest(paras) x)
    || '<p><a href="https://leadfarminghq.com/app/" style="display:inline-block;background:#58CC02;color:#fff;font-weight:bold;text-decoration:none;padding:12px 20px;border-radius:10px">Open the portal</a></p>'
    || '<p>Alex<br>Lead Farming</p>'
    || '<p style="font-size:12px;color:#777">You get these emails because you are enrolled in the Lead Farming Mentoring Program. Questions? Reply to this email or write to support@leadfarminghq.com.</p></div>';
$$;

-- at most one email per farmer per day
create or replace function ops.emailed_today(f uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nudges where farmer_id = f and emailed and created_at >= date_trunc('day', now()));
$$;

create or replace function ops.first_name(f uuid) returns text language sql stable security definer set search_path = public as $$
  select split_part(btrim(coalesce(full_name, '')), ' ', 1) from public.profiles where id = f;
$$;

-- ---------- the daily run ----------
-- Each stuck reason is nudged once (no contractors; each missed quota), or every 3 days (nothing logged).
-- A farmer gets at most one email a day (the most urgent reason); the other reasons still show in the portal.
-- Then weekly progress emails go to farmers who haven't had one in 7 days. Emails stop at the daily cap;
-- the in-portal alerts always go out. Returns how many alerts and emails went out.
create or replace function ops.run_nudges() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  p record; r jsonb; msg text; subj text; paras text[]; sent boolean; n_alerts int := 0; n_emails int := 0;
  pr jsonb; nxt jsonb; c_week int; c_all int; calls_week int; comm_week int; met int; total int;
begin
  for p in select pp.id, pp.email from public.profiles pp
           where pp.role = 'farmer' and pp.enrollment_paid and not pp.comp and pp.enrolled_at is not null
           order by pp.enrolled_at loop
    for r in select * from jsonb_array_elements(public.stuck_reasons(p.id))
             order by case r->>'kind' when 'no_contractors' then 0 when 'behind' then 1 else 2 end loop
      continue when exists (select 1 from public.nudges n where n.farmer_id = p.id and n.kind = r->>'kind' and n.detail = r->>'key'
        and (r->>'kind' <> 'inactive' or n.created_at > now() - interval '3 days'));
      if r->>'kind' = 'no_contractors' then
        msg := 'You haven''t added a contractor yet. Open Pipeline, press Add, and log the first one you find today. The Level 1 lessons show you where to look.';
        subj := 'Your first contractor';
      elsif r->>'kind' = 'inactive' then
        msg := 'We haven''t seen anything logged in the portal for a few days. Log today''s calls or comments, even a few, to keep your 5-days-a-week streak going. Stuck on something? Ask a teacher from the Learn page.';
        subj := 'Pick up where you left off';
      else
        msg := r->>'text' || '. The 90 days page shows what''s left. Catch up as soon as you can, and ask a teacher from the Learn page if you''re stuck.';
        subj := 'A 90-day goal date has passed';
      end if;
      -- an alert they haven't dismissed yet isn't stacked again
      if not exists (select 1 from public.notifications x where x.farmer_id = p.id and x.body = msg and x.read_at is null) then
        insert into public.notifications (farmer_id, body) values (p.id, msg);
        n_alerts := n_alerts + 1;
      end if;
      sent := false;
      if ops.emails_today() < ops.email_cap() and not ops.emailed_today(p.id) then
        sent := ops.send_email(p.email, subj, ops.email_html(ops.first_name(p.id), array[msg]));
      end if;
      if sent then n_emails := n_emails + 1; end if;
      insert into public.nudges (farmer_id, kind, detail, emailed) values (p.id, r->>'kind', r->>'key', sent);
    end loop;
  end loop;

  -- weekly progress email, during the 90 days (plus the week to send the refund package)
  for p in select pp.id, pp.email, pp.enrolled_at from public.profiles pp
           where pp.role = 'farmer' and pp.enrollment_paid and not pp.comp and pp.enrolled_at is not null
             and pp.enrolled_at < now() - interval '6 days' and pp.enrolled_at > now() - interval '97 days'
             and not exists (select 1 from public.nudges n where n.farmer_id = pp.id and n.kind = 'weekly' and n.created_at > now() - interval '6 days 20 hours')
             and not ops.emailed_today(pp.id)
           order by pp.enrolled_at loop
    exit when ops.emails_today() >= ops.email_cap();
    pr := public.refund_progress(p.id);
    select count(*) filter (where created_at > now() - interval '7 days'), count(*) into c_week, c_all from public.contractors where farmer_id = p.id;
    select count(*) filter (where kind = 'call'), coalesce(sum(count) filter (where kind = 'comments'), 0) into calls_week, comm_week
      from public.activities where farmer_id = p.id and created_at > now() - interval '7 days';
    select count(*) filter (where (s->>'met')::boolean), count(*) into met, total from jsonb_array_elements(pr->'steps') s;
    select s into nxt from jsonb_array_elements(pr->'steps') s where not (s->>'met')::boolean and (s->>'deadline')::int >= (pr->>'day')::int
      order by (s->>'deadline')::int limit 1;
    paras := array[
      'Here''s your week. You''re on day ' || least((pr->>'day')::int, 90) || ' of 90.',
      'This week: ' || c_week || ' contractors added (' || c_all || ' in total), ' || calls_week || ' calls logged, ' || comm_week || ' neighbor comments logged.',
      met || ' of ' || total || ' program steps met.'
        || coalesce(' Next up: step ' || (nxt->>'n') || ', ' || (nxt->>'name') || ', ' || (nxt->>'quota') || ', by day ' || (nxt->>'deadline') || '. You''re at ' || (nxt->>'progress') || '.', '')];
    sent := ops.send_email(p.email, 'Your week in Lead Farming: day ' || least((pr->>'day')::int, 90) || ' of 90', ops.email_html(ops.first_name(p.id), paras));
    exit when not sent;  -- no Resend key yet
    insert into public.nudges (farmer_id, kind, detail, emailed) values (p.id, 'weekly', 'day ' || (pr->>'day'), true);
    n_emails := n_emails + 1;
  end loop;
  return n_alerts || ' alerts, ' || n_emails || ' emails';
end $$;

revoke execute on all functions in schema ops from public, anon, authenticated;

-- every day at 15:00 UTC (10am Central, 9am in winter)
select cron.unschedule('activation-nudges') where exists (select 1 from cron.job where jobname = 'activation-nudges');
select cron.schedule('activation-nudges', '0 15 * * *', $$select ops.run_nudges()$$);

-- ---------- booking funnel: calls with Alex (20261014_booking.sql) ----------
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

-- ---------- tracking: how they heard about us, ad tags (20261014_tracking.sql) ----------
-- Tracking (Alex, 2026-10-14): how each farmer heard about us (asked at sign-up) and the ad tags
-- (utm_*, fbclid, ?ref) from their first visit, stored on the profile for the Monday report's source breakdown.
alter table public.profiles add column if not exists heard_about text check (length(heard_about) <= 80);
alter table public.profiles add column if not exists attribution jsonb not null default '{}';

-- same as before, plus heard_about and the first-visit tags from the sign-up form
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare rec uuid; m jsonb := new.raw_user_meta_data;
begin
  select id into rec from public.profiles
   where lower(email) = lower(nullif(trim(m->>'recruiter_email'), ''));
  insert into public.profiles (id, email, full_name, phone, recruited_by, heard_about, attribution)
  values (new.id, new.email, m->>'full_name', m->>'phone', rec, left(nullif(btrim(m->>'heard_about'), ''), 80),
    coalesce((select jsonb_object_agg(k, left(v, 200)) from jsonb_each_text(case when jsonb_typeof(m->'attribution') = 'object' then m->'attribution' else '{}' end) x(k, v)
      where k in ('utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'fbclid', 'ref', 'landing', 'referrer', 'first_seen')), '{}'));
  if rec is not null then
    insert into public.recruiter_payouts (recruiter_id, recruit_id) values (rec, new.id);
  end if;
  return new;
end $$;

-- Where a farmer came from, in one word, for reports: an ad, a referral, a call with Alex, or what they told us
create or replace function public.source_of(p public.profiles) returns text
language sql stable security definer set search_path = public as $$
  select case
    when lower(coalesce(p.attribution->>'utm_source', '')) in ('facebook', 'fb', 'instagram', 'ig', 'meta') or p.attribution ? 'fbclid'
      or p.heard_about = 'Facebook or Instagram ad' then 'Meta ads'
    when p.recruited_by is not null or p.heard_about = 'A friend or family member' then 'Referral'
    when exists (select 1 from public.call_requests c where c.profile_id = p.id) or p.heard_about = 'Talked with Alex' then 'Call with Alex'
    when nullif(p.attribution->>'utm_source', '') is not null then initcap(p.attribution->>'utm_source')
    else coalesce(nullif(p.heard_about, ''), 'Unknown') end;
$$;
revoke execute on function public.source_of(public.profiles) from public, anon, authenticated;

-- ---------- Monday report additions, ad spend (20261014_monday_report.sql) ----------
-- Monday report additions (Alex, 2026-10-14): real revenue (comp accounts left out), new paid this week,
-- booked calls and show rate, where buyers came from, ad spend against the $3,750 budget, sales and cost per
-- sale from ads, leads sent, first fees, and inactive farmers. Ad spend is typed in by Alex on Home.

create table if not exists public.ad_spend (
  id bigint generated always as identity primary key,
  spent_on date not null,
  amount numeric(10, 2) not null check (amount > 0 and amount < 100000),
  note text check (length(note) <= 200),
  created_at timestamptz not null default now());
alter table public.ad_spend enable row level security;
create policy "ad spend admin" on public.ad_spend for all using (public.is_admin()) with check (public.is_admin());

-- The 2026 ad budget, in 3 stages ($3,750 in all)
create or replace function public.ad_stages() returns table (stage text, starts date, ends date, budget numeric)
language sql immutable as $$
  values ('Stage 1', date '2026-11-01', date '2026-11-14', 500::numeric),
         ('Stage 2', date '2026-11-15', date '2026-11-30', 1250::numeric),
         ('Stage 3', date '2026-12-01', date '2026-12-24', 2000::numeric);
$$;

-- Admin Home "Ads" card: spend by stage, sales from ads, cost per sale, every entry
create or replace function public.ad_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare spent numeric; sales int;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select coalesce(sum(amount), 0) into spent from public.ad_spend;
  select count(*) into sales from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp and public.source_of(p) = 'Meta ads';
  return jsonb_build_object(
    'stages', (select jsonb_agg(jsonb_build_object('stage', s.stage, 'starts', s.starts, 'ends', s.ends, 'budget', s.budget,
        'spent', (select coalesce(sum(a.amount), 0) from public.ad_spend a where a.spent_on between s.starts and s.ends)) order by s.starts)
      from public.ad_stages() s),
    'spent', spent, 'budget', (select sum(budget) from public.ad_stages()),
    'sales', sales, 'cost_per_sale', case when sales > 0 then round(spent / sales, 2) end,
    'entries', coalesce((select jsonb_agg(to_jsonb(a) order by a.spent_on desc, a.id desc) from public.ad_spend a), '[]'));
end $$;
revoke execute on function public.ad_summary() from public, anon;
grant execute on function public.ad_summary() to authenticated;

-- The Monday report (Telegram), covering the 7 days before it runs
create or replace function ops.weekly_report() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  t1 timestamptz := now(); t0 timestamptz := now() - interval '7 days';
  rev numeric; paid_n int; new_names text; comm numeric; owed numeric; refunds int;
  rev_all numeric; comm_all numeric; farmers_all int; comps int;
  signups int; contractors_new int; leads_sent int; leads_closed int; fees numeric; first_fees text; levelups int;
  booked int; held int; showed int; no_show int; from_calls int; requests int;
  src_week text; src_all text;
  spend_week numeric; spend_all numeric; ad_sales_week int; ad_sales_all int; stage_line text;
  inactive text; inactive_n int;
  w_levels int; w_questions int; w_niches int; w_refunds int;
  goal numeric := 30000; days_left int := greatest(0, date '2026-12-31' - (now() at time zone 'America/Chicago')::date);
begin
  -- money: only farmers who actually paid
  select count(*), sum(enrollment_fee), string_agg(coalesce(nullif(btrim(full_name), ''), email), ', ' order by enrolled_at)
    into paid_n, rev, new_names from public.profiles
    where role = 'farmer' and enrollment_paid and not comp and enrolled_at >= t0 and enrolled_at < t1;
  select sum(enrollment_fee), count(*) into rev_all, farmers_all from public.profiles where role = 'farmer' and enrollment_paid and not comp;
  select count(*) into comps from public.profiles where role = 'farmer' and enrollment_paid and comp;
  select sum(amount) into comm from public.recruiter_payouts where status = 'paid' and not not_cash and paid_at >= t0 and paid_at < t1;
  select sum(amount) into comm_all from public.recruiter_payouts where status = 'paid' and not not_cash;
  select sum(amount) into owed from public.recruiter_payouts where status = 'owed';
  select count(*) into refunds from public.refund_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;

  -- calls with Alex
  select count(*) into requests from public.call_requests where created_at >= t0 and created_at < t1;
  select count(*) into booked from public.call_requests where booked_at >= t0 and booked_at < t1;
  select count(*) filter (where status in ('showed', 'no_show', 'enrolled', 'booked')), count(*) filter (where status in ('showed', 'enrolled')),
         count(*) filter (where status = 'no_show')
    into held, showed, no_show from public.call_requests where call_at >= t0 and call_at < t1;
  select count(*) into from_calls from public.call_requests c join public.profiles p on p.id = c.profile_id
    where c.status = 'enrolled' and p.enrolled_at >= t0 and p.enrolled_at < t1;

  -- where buyers came from
  select string_agg(s || ' ' || n, ', ' order by n desc, s) into src_week from (
    select public.source_of(p) s, count(*) n from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.comp and p.enrolled_at >= t0 and p.enrolled_at < t1 group by 1) x;
  select string_agg(s || ' ' || n, ', ' order by n desc, s) into src_all from (
    select public.source_of(p) s, count(*) n from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.comp group by 1) x;

  -- ads
  select sum(amount) into spend_week from public.ad_spend where spent_on >= (t0 at time zone 'America/Chicago')::date and spent_on <= (t1 at time zone 'America/Chicago')::date;
  select sum(amount) into spend_all from public.ad_spend;
  select count(*) filter (where p.enrolled_at >= t0 and p.enrolled_at < t1), count(*) into ad_sales_week, ad_sales_all
    from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp and public.source_of(p) = 'Meta ads';
  select s.stage || ' (' || to_char(s.starts, 'Mon DD') || ' to ' || to_char(s.ends, 'Mon DD') || '): '
      || ops.money((select coalesce(sum(a.amount), 0) from public.ad_spend a where a.spent_on between s.starts and s.ends))
      || ' of ' || ops.money(s.budget)
    into stage_line from public.ad_stages() s
    where (now() at time zone 'America/Chicago')::date <= s.ends order by s.starts limit 1;

  -- the farmers' work
  select count(*) into signups from public.profiles where role = 'farmer' and created_at >= t0 and created_at < t1;
  select count(*) into contractors_new from public.contractors where created_at >= t0 and created_at < t1;
  select count(*) into leads_sent from public.leads where direction = 'outbound' and created_at >= t0 and created_at < t1;
  select count(*) into leads_closed from public.leads where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select sum(fee_amount) into fees from public.leads where fee_paid and fee_paid_at >= t0 and fee_paid_at < t1;
  select string_agg(ops.who(farmer_id), ', ') into first_fees from (
    select farmer_id from public.leads where fee_paid and fee_paid_at is not null group by farmer_id
    having min(fee_paid_at) >= t0 and min(fee_paid_at) < t1) x;
  select count(*) into levelups from public.level_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select count(*), string_agg(nm, ', ' order by nm) into inactive_n, inactive from (
    select coalesce(nullif(btrim(p.full_name), ''), p.email) nm from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.comp and p.enrolled_at < now() - interval '7 days'
      and p.enrolled_at > now() - interval '97 days'
      and coalesce(public.last_active(p.id), p.enrolled_at) < now() - interval '7 days') x;

  select count(*) into w_levels from public.level_requests where status = 'pending';
  select count(*) into w_questions from public.teacher_questions where answer is null;
  select count(*) into w_niches from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null;
  select count(*) into w_refunds from public.refund_requests where status = 'pending';

  return '📊 Monday report: ' || to_char(t0 at time zone 'America/Chicago', 'Mon DD') || ' to '
    || to_char(t1 at time zone 'America/Chicago', 'Mon DD') || E'\n\n'
    || E'💰 Money (this week)\n'
    || 'New paid farmers: ' || paid_n || coalesce(' (' || new_names || ')', '') || E'\n'
    || 'Real revenue: ' || ops.money(rev) || E' (before Stripe fees, free accounts left out)\n'
    || 'Bonuses paid out: ' || ops.money(comm) || ', still owed: ' || ops.money(owed) || E'\n'
    || 'Refunds approved: ' || refunds || E'\n\n'
    || E'🎯 $30k goal\n'
    || ops.money(rev_all) || ' of ' || ops.money(goal) || ' (' || round(100 * coalesce(rev_all, 0) / goal) || '%) from ' || farmers_all || ' paying farmers'
    || case when comps > 0 then ' (+' || comps || ' free)' else '' end || E'\n'
    || 'About ' || ceil(greatest(0, goal - coalesce(rev_all, 0)) / 499) || ' more farmers at $499 by Dec 31, ' || days_left || E' days left\n\n'
    || E'📞 Calls with you\n'
    || 'Forms filled: ' || requests || ', calls booked: ' || booked || E'\n'
    || 'Calls held: ' || held || ', showed: ' || showed || ', no-shows: ' || no_show
    || case when showed + no_show > 0 then ', show rate ' || round(100.0 * showed / (showed + no_show)) || '%' else '' end || E'\n'
    || 'Enrolled after a call: ' || from_calls || E'\n\n'
    || E'🧭 Where buyers came from\n'
    || 'This week: ' || coalesce(src_week, 'nobody new') || E'\n'
    || 'All time: ' || coalesce(src_all, 'nobody yet') || E'\n\n'
    || E'📣 Ads\n'
    || 'Spend this week: ' || ops.money(spend_week) || ', total: ' || ops.money(spend_all) || E' of $3,750\n'
    || coalesce(stage_line || E'\n', '')
    || 'Sales from ads: ' || ad_sales_week || ' this week, ' || ad_sales_all || E' total\n'
    || 'Cost per sale from ads: ' || case when ad_sales_all > 0 then ops.money(coalesce(spend_all, 0) / ad_sales_all) else 'no ad sales yet' end || E'\n\n'
    || E'🌱 Farmers (this week)\n'
    || 'New signups: ' || signups || ', contractors added: ' || contractors_new || E'\n'
    || 'Leads sent: ' || leads_sent || ', closed: ' || leads_closed || ', fees collected: ' || ops.money(fees) || E'\n'
    || 'First fees: ' || coalesce(first_fees, 'none') || E'\n'
    || 'Level-ups approved: ' || levelups || E'\n'
    || 'Inactive 7+ days: ' || inactive_n || coalesce(' (' || inactive || ')', '') || E'\n\n'
    || E'⏳ Waiting on you\n'
    || 'Level-up requests: ' || w_levels || ', questions: ' || w_questions
    || ', niches: ' || w_niches || ', refunds: ' || w_refunds || E'\n'
    || 'https://leadfarminghq.com/app/';
end;
$$;
revoke execute on all functions in schema ops from public, anon, authenticated;
-- Refund rule for new enrollments (Alex, 2026-10-14, "Yes, both"): from Terms version 2026-10-14, $250 recruiting
-- bonuses no longer reduce the refund. Farmers who accepted an earlier version (2026-10-08 or 2026-10-08.2) keep the
-- rule they agreed to, where bonuses paid by day 90 count toward paying them back. A paid farmer who hasn't accepted
-- any version yet follows the rule that was current when they enrolled.
create or replace function public.bonuses_reduce_refund(p public.profiles) returns boolean
language sql stable set search_path = public as $$
  select case when p.terms_version is not null then p.terms_version < '2026-10-14'
              else coalesce(p.enrolled_at < timestamptz '2026-10-14 00:00:00-05', false) end
$$;

create or replace function public.refund_progress(p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f uuid := coalesce(p_farmer, auth.uid());
  p public.profiles;
  t0 timestamptz;
  d int;
  steps jsonb := '[]';
  v1 int; v2 int; v3 int; ok boolean;
  fees numeric := 0;
  bonuses numeric := 0;
begin
  if f <> auth.uid() and not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into p from public.profiles where id = f;
  if p.id is null or not p.enrollment_paid or p.enrolled_at is null then return jsonb_build_object('enrolled', false); end if;
  t0 := p.enrolled_at;
  d := floor(extract(epoch from now() - t0) / 86400)::int;

  -- 0: 15 business models approved by day 3
  ok := p.niche_approved_at is not null and p.niche_submitted_at <= t0 + interval '3 days';  -- sent in time; review may land later
  steps := steps || jsonb_build_object('n', 0, 'name', 'Niche + 15 trades', 'quota', '15 business models, approved', 'deadline', 3,
    'progress', case when p.niche_approved_at is not null then 'Approved' when p.niche_note is not null then 'Sent back' when p.niche_submitted_at is not null then 'Waiting for review' else 'Not sent yet' end, 'met', ok);

  -- 1: 300 contractors with phone + source link, 20 in each of 15 trades, by day 14
  select coalesce(sum(n), 0), count(*) filter (where n >= 20 and trade_id is not null) into v1, v2 from (
    select c.trade_id, count(*) n from public.contractors c
    where c.farmer_id = f and c.created_at <= t0 + interval '14 days' and coalesce(c.phone, '') <> '' and coalesce(c.source_link, '') <> ''
    group by c.trade_id) x;
  steps := steps || jsonb_build_object('n', 1, 'name', 'Contractor Identified', 'quota', '300 contractors (20 in each of 15 trades), with phone and source link', 'deadline', 14,
    'progress', v1 || ' of 300 · ' || v2 || ' of 15 trades at 20', 'met', v1 >= 300 and v2 >= 15);

  -- 2: 300 contractors called by day 21; every "agreed" call has the 20% text
  select count(*), count(*) filter (where said_yes and not texted) into v1, v2 from (
    select a.contractor_id, bool_or(a.outcome = 'agreed') said_yes, bool_or(a.text_sent) texted
    from public.activities a where a.farmer_id = f and a.kind = 'call' and a.contractor_id is not null
      and a.created_at <= t0 + interval '21 days' group by a.contractor_id) x;
  steps := steps || jsonb_build_object('n', 2, 'name', 'Outreach Made', 'quota', '300 calls, plus the 20% text to every yes', 'deadline', 21,
    'progress', v1 || ' of 300 called' || case when v2 > 0 then ' · ' || v2 || ' yes without the 20% text' else '' end, 'met', v1 >= 300 and v2 = 0);

  -- 3: 150 contractors at Terms Agreed (stage 3+), 10 in each of 15 trades, by day 45
  select coalesce(sum(n), 0), count(*) filter (where n >= 10 and trade_id is not null) into v1, v2 from (
    select c.trade_id, count(*) n from public.contractors c
    where c.farmer_id = f and exists (select 1 from public.contractor_stage_history h
      where h.contractor_id = c.id and h.to_stage >= 3 and h.changed_at <= t0 + interval '45 days')
    group by c.trade_id) x;
  steps := steps || jsonb_build_object('n', 3, 'name', 'Terms Agreed', 'quota', '150 agreed, 10 in each of 15 trades', 'deadline', 45,
    'progress', v1 || ' of 150 · ' || v2 || ' of 15 trades at 10', 'met', v1 >= 150 and v2 >= 15);

  -- 4: 50 comments a day on 5 days of every week from day 7 to day 90; 300 leads to 100+ contractors by day 75
  select count(*) filter (where good_days >= 5) into v3 from (
    select w, (select count(*) from (
        select date_trunc('day', a.created_at - t0) dd from public.activities a
        where a.farmer_id = f and a.kind = 'comments'
          and a.created_at >= t0 + make_interval(days => 7 + 7 * w) and a.created_at < t0 + make_interval(days => 14 + 7 * w)
        group by 1 having sum(a.count) >= 50) z) good_days
    from generate_series(0, 11) w) y;
  select count(*), count(distinct l.contractor_id) into v1, v2 from public.leads l
    where l.farmer_id = f and l.direction = 'outbound' and l.created_at <= t0 + interval '75 days';
  steps := steps || jsonb_build_object('n', 4, 'name', 'First Lead Sent', 'quota', '50 comments a day, 5 days a week (days 7 to 90); 300 leads to 100+ contractors by day 75', 'deadline', 75,
    'progress', v3 || ' of 12 comment weeks · ' || v1 || ' of 300 leads · ' || v2 || ' of 100 contractors', 'met', v3 >= 12 and v1 >= 300 and v2 >= 100);

  -- referral fees actually received by day 90 (fee_paid_at is stamped by the server when marked paid);
  -- the refund is the price they paid minus these and the recruiting bonuses below
  select coalesce(sum(l.fee_amount), 0) into fees from public.leads l
    where l.farmer_id = f and l.direction = 'outbound' and l.status = 'closed' and l.fee_paid and l.fee_paid_at <= t0 + interval '90 days';
  -- $250 recruiting bonuses paid by day 90 reduce the refund only for farmers on the older Terms (see bonuses_reduce_refund);
  -- a bonus taken back after its recruit's refund doesn't count
  if public.bonuses_reduce_refund(p) then
    select coalesce(sum(r.amount), 0) into bonuses from public.recruiter_payouts r
      where r.recruiter_id = f and r.status = 'paid' and r.paid_at <= t0 + interval '90 days' and r.clawback_at is null;
  end if;

  -- rules: activity on 5 of every 7 days (13 weeks, days 0-90); quizzes for every level reached
  select count(*) filter (where days >= least(5, len)) into v1 from (
    select w, least(7, 91 - 7 * w) len, (select count(distinct floor(extract(epoch from x.t - t0) / 86400)) from (
        select created_at t from public.contractors where farmer_id = f
        union all select created_at from public.leads where farmer_id = f
        union all select created_at from public.activities where farmer_id = f
        union all select created_at from public.upsells where farmer_id = f
        union all select h.changed_at from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = f) x
      where x.t >= t0 + make_interval(days => 7 * w) and x.t < t0 + make_interval(days => least(7 * w + 7, 91))) days
    from generate_series(0, 12) w) y;
  select count(distinct q.quiz) into v2 from public.quiz_passes q where q.farmer_id = f
    and q.quiz in (select 'l' || g from generate_series(1, greatest(p.level, 1)) g);

  return jsonb_build_object(
    'enrolled', true, 'paid_at', t0, 'day', d,
    'end_at', t0 + interval '90 days', 'submit_by', t0 + interval '97 days',
    'steps', steps,
    'rules', jsonb_build_array(
      jsonb_build_object('name', 'Portal activity on 5 of every 7 days', 'progress', v1 || ' of 13 weeks', 'met', v1 >= 13),
      jsonb_build_object('name', 'Quizzes aced for every level reached', 'progress', v2 || ' of ' || greatest(p.level, 1), 'met', v2 >= greatest(p.level, 1))),
    'all_met', not exists (select 1 from jsonb_array_elements(steps) s where not (s->>'met')::boolean) and v1 >= 13 and v2 >= greatest(p.level, 1),
    'price', p.enrollment_fee, 'fees', fees, 'bonuses', bonuses, 'bonuses_count', public.bonuses_reduce_refund(p), 'refund_amount', greatest(0, p.enrollment_fee - fees - bonuses),
    'niche', p.niche, 'niche_note', p.niche_note,
    'comments_today', (select coalesce(sum(a.count), 0) from public.activities a
      where a.farmer_id = f and a.kind = 'comments' and a.created_at >= date_trunc('day', now())));
end $$;

create or replace function public.submit_refund_package(p_note text, p_files text[] default '{}') returns uuid
language plpgsql security definer set search_path = public as $$
declare pr jsonb; rid uuid;
begin
  pr := public.refund_progress(auth.uid());
  if not coalesce((pr->>'enrolled')::boolean, false) then raise exception 'Finish your enrollment first'; end if;
  if now() > (pr->>'submit_by')::timestamptz then raise exception 'The refund window closed on day 97'; end if;
  if not (pr->>'all_met')::boolean then raise exception 'Every quota has to be met before you can send the package'; end if;
  if (pr->>'refund_amount')::numeric <= 0 then raise exception 'What you received by day 90 reached what you paid, so no refund is owed'; end if;
  if coalesce(cardinality(p_files), 0) = 0 then raise exception 'Attach your evidence files'; end if;
  if exists (select 1 from unnest(p_files) x where x not like auth.uid()::text || '/%') then
    raise exception 'Evidence files must be your own uploads';
  end if;
  if exists (select 1 from public.refund_requests where farmer_id = auth.uid() and status in ('pending', 'approved')) then
    raise exception 'Your refund package was already sent';
  end if;
  insert into public.refund_requests (farmer_id, note, files, progress)
  values (auth.uid(), nullif(btrim(p_note), ''), p_files, pr) returning id into rid;
  return rid;
end $$;

-- ---------- Growth tab (20261016_growth.sql) ----------
-- Growth tab (Alex, 2026-10-16): the owner's checklist for the $30k-by-Dec-31 plan. Benchmarks ("goals") are
-- what we want to hit, each with the steps we're taking to get there. A goal can track a live number from the
-- database (metric + target); the rest are ticked by hand. Owner (admin) only.
create table if not exists public.growth_items (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('goal', 'step')),
  goal_id bigint references public.growth_items(id) on delete cascade,  -- a step belongs to a goal
  title text not null check (length(btrim(title)) between 1 and 200),
  detail text check (length(detail) <= 1000),
  link text check (link ~ '^https://' and length(link) <= 500),
  who text check (length(who) <= 60),             -- who's doing the step: Alex, Claude, the teachers
  metric text check (metric ~ '^[a-z_]{1,40}$'),  -- a key from growth_numbers()
  target numeric,
  lower_is_better boolean not null default false, -- e.g. cost per sale
  due date,
  done_at timestamptz,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check ((kind = 'goal') = (goal_id is null)));
create index if not exists growth_items_goal on public.growth_items (goal_id);
alter table public.growth_items enable row level security;
create policy "growth admin" on public.growth_items for all using (public.is_admin()) with check (public.is_admin());

-- The live numbers the goals track. Free (comp) accounts are left out, same as the dashboard and Monday report.
create or replace function public.growth_numbers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; showed int; no_show int; spent numeric; ad_sales int;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select count(*) filter (where status in ('showed', 'enrolled') and call_at is not null), count(*) filter (where status = 'no_show')
    into showed, no_show from public.call_requests;
  select coalesce(sum(amount), 0) into spent from public.ad_spend;
  select count(*) into ad_sales from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp and public.source_of(p) = 'Meta ads';
  with payers as (select * from public.profiles where role = 'farmer' and enrollment_paid and not comp)
  select jsonb_build_object(
    'revenue', coalesce((select sum(enrollment_fee) from payers), 0),
    'payers', (select count(*) from payers),
    'new_paid_week', (select count(*) from payers where enrolled_at > now() - interval '7 days'),
    'new_paid_4wk', (select count(*) from payers where enrolled_at > now() - interval '28 days'),
    'calls_booked_week', (select count(*) from public.call_requests where booked_at > now() - interval '7 days'),
    'calls_booked', (select count(*) from public.call_requests where booked_at is not null),
    'show_rate', case when showed + no_show > 0 then round(100.0 * showed / (showed + no_show)) end,
    'ad_spend', spent,
    'ad_sales', ad_sales,
    'cost_per_sale', case when ad_sales > 0 then round(spent / ad_sales, 2) end,
    'referral_sales', (select count(*) from payers p where public.source_of(p) = 'Referral'),
    'activated_pct', (select case when count(*) > 0 then round(100.0 * count(*) filter (where exists (select 1 from public.contractors c where c.farmer_id = p.id)) / count(*)) end from payers p),
    'active_week_pct', (select case when count(*) > 0 then round(100.0 * count(*) filter (where public.last_active(p.id) > now() - interval '7 days') / count(*)) end from payers p),
    'leads_sent', (select count(*) from public.leads where direction = 'outbound'),
    'farmers_with_fee', (select count(distinct farmer_id) from public.leads where fee_paid),
    'level2', (select count(*) from payers where level >= 2)) into r;
  return r;
end $$;
revoke execute on function public.growth_numbers() from public, anon;
grant execute on function public.growth_numbers() to authenticated;

-- Starting checklist, from the growth plan Alex approved 2026-10-14. Only filled in once, on an empty table.
do $$
declare g bigint;
begin
  if exists (select 1 from public.growth_items) then return; end if;

  insert into public.growth_items (kind, title, detail, metric, target, due, sort_order) values
    ('goal', '$30,000 in enrollment revenue', 'The main goal. About 5 new paying farmers a week at $499 gets there.', 'revenue', 30000, '2026-12-31', 10)
    returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, done_at, sort_order) values
    ('step', g, 'Free accounts (zim, Julian) left out of revenue; Drew marked paid', 'Alex', now(), 1),
    ('step', g, 'Monday report on Telegram tracks the goal, calls and ads', 'Claude', now(), 2);

  insert into public.growth_items (kind, title, detail, metric, target, due, sort_order) values
    ('goal', 'Checkpoint: $10,000', 'Halfway-to-pace check before ads ramp up.', 'revenue', 10000, '2026-11-15', 20),
    ('goal', 'Checkpoint: $20,000', 'Where we need to be going into the biggest ad stage.', 'revenue', 20000, '2026-12-01', 30);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', '5 new paying farmers a week', 'Last 7 days. The pace the $30k goal needs.', 'new_paid_week', 5, 40) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, '"Book a call with Alex" on the landing page', 'Claude', 'https://leadfarminghq.com/', now(), 1),
    ('step', g, '"Share your link" card on every farmer''s Home', 'Claude', null, now(), 2),
    ('step', g, 'Send the founder video for the "Meet Alex" section', 'Alex', null, null, 3);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', '10 booked calls a week', 'Last 7 days. Assumes about half of calls enroll, so 10 calls makes 5 sales.', 'calls_booked_week', 10, 50) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, 'Cal.com calendar on the landing page', 'Claude', 'https://cal.com/zimbux/intro-call', now(), 1),
    ('step', g, 'Meta pixel tracking page views, bookings and payments', 'Claude', 'https://business.facebook.com/events_manager2', now(), 2),
    ('step', g, 'Add the Cal.com webhook so booked calls reach Telegram and Home', 'Alex', 'https://app.cal.com/settings/developer/webhooks', null, 3);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', 'Show rate of 70% or better', 'Of calls that have happened, how many people showed up.', 'show_rate', 70, 60) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, sort_order) values
    ('step', g, 'Mark Showed or No-show on each call under "Calls with you" on Home', 'Alex', 'https://leadfarminghq.com/app/', 1);

  insert into public.growth_items (kind, title, detail, metric, target, lower_is_better, due, sort_order) values
    ('goal', 'Ads: cost per sale under $250', '$3,750 budget in 3 stages. Ad copy: no income figures, no "guarantee", never mention the recruiting bonus.', 'cost_per_sale', 250, true, '2026-12-24', 70)
    returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, due, sort_order) values
    ('step', g, 'Stage 1: $500, Nov 1 to 14', 'Alex', 'https://adsmanager.facebook.com/', '2026-11-01', 1),
    ('step', g, 'Stage 2: $1,250, Nov 15 to 30', 'Alex', 'https://adsmanager.facebook.com/', '2026-11-15', 2),
    ('step', g, 'Stage 3: $2,000, Dec 1 to 24', 'Alex', 'https://adsmanager.facebook.com/', '2026-12-01', 3),
    ('step', g, 'Log ad spend each week in the Ads card on Home', 'Alex', 'https://leadfarminghq.com/app/', null, 4);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', 'Every paid farmer has contractors', 'Share of paying farmers with at least one contractor logged.', 'activated_pct', 100, 80) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, 'Daily nudges to stuck farmers (alerts and email)', 'Claude', null, now(), 1),
    ('step', g, 'Julian and Vincent set as teachers', 'Alex', null, now(), 2),
    ('step', g, 'Hand each stuck farmer to a teacher on Home', 'Alex', 'https://leadfarminghq.com/app/', null, 3);

  insert into public.growth_items (kind, title, detail, metric, target, due, sort_order) values
    ('goal', 'First farmer earns a referral fee', 'Real results are the proof every ad and call leans on.', 'farmers_with_fee', 1, '2026-11-15', 90) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, sort_order) values
    ('step', g, '30-day "first fee" push with the current farmers', 'Alex and teachers', 1),
    ('step', g, 'Ask the first earners for a case study (with permission)', 'Alex', 2);

  insert into public.growth_items (kind, title, detail, due, sort_order) values
    ('goal', 'Ready for ads', 'Compliance in place before the first ad dollar.', '2026-11-01', 100) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, 'Lesson 4b script discloses the referral fee', 'Claude', null, now(), 1),
    ('step', g, 'New Terms: bonuses never reduce new farmers'' refunds', 'Claude', 'https://leadfarminghq.com/terms/', now(), 2),
    ('step', g, 'Privacy Policy and cookie notice for the pixel', 'Claude', 'https://leadfarminghq.com/privacy/', now(), 3),
    ('step', g, 'File the LLC (Lead Farming HQ LLC)', 'Alex', 'https://www.sos.state.tx.us/corp/sosda/index.shtml', null, 4),
    ('step', g, 'Have a Texas business lawyer look over the Terms', 'Alex', null, null, 5);
end $$;
