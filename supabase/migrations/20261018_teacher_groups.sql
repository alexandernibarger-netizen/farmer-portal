-- ---------- teachers pick their students (20261018_teacher_groups.sql) ----------
-- Alex, 2026-10-18: Vincent Beck and Julian (verifiers) each pick up to 4 paid farmers in the portal.
-- From then on that teacher answers the farmer's questions and reviews their level-ups and 15 business models;
-- Alex only gets what comes from farmers with no teacher. Refund packages stay with Alex (he refunds in Stripe).
-- Goal: $1,000 of job value through each student's pipeline every 2 weeks, so $4,000 per teacher, $8,000 for both.

-- from the teacher welcome popup (PR #37); already on the live database
alter table public.profiles add column if not exists teacher_welcome_seen boolean not null default false;
alter table public.profiles add column if not exists teacher_guide_seen boolean not null default false;
alter table public.profiles add column if not exists teacher_since timestamptz;

create or replace function public.teacher_cap() returns int language sql immutable as 'select 4';
create or replace function public.student_goal() returns numeric language sql immutable as 'select 1000::numeric';
create or replace function public.goal_window() returns interval language sql immutable as $$ select interval '14 days' $$;

-- a person's display name
create or replace function public.ops_name(f uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(full_name), ''), email) from public.profiles where id = f;
$$;

-- A farmer's teacher, if it's an active teacher (a ticked verifier, not Alex)
create or replace function public.teacher_of(f uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select t.id from public.profiles p join public.profiles t on t.id = p.teacher_id
  where p.id = f and t.verifier and t.role <> 'admin';
$$;
-- Whose job is this farmer's stuff: their teacher, or Alex when they have none. Alex can always step in.
create or replace function public.teaches(f uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or coalesce(public.is_verifier() and public.teacher_of(f) = auth.uid(), false);
$$;
-- Is this item on the signed-in person's own list (the badge and "Needs you")
create or replace function public.mine_to_review(f uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then public.teacher_of(f) is null else public.teaches(f) end;
$$;

-- No teacher gets more than 4 students (Alex himself has no cap)
create or replace function public.check_teacher_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.teacher_id is distinct from old.teacher_id then
    new.teacher_since := case when new.teacher_id is null then null else now() end;
    if new.teacher_id is not null and not exists (select 1 from public.profiles where id = new.teacher_id and role = 'admin') then
      perform 1 from public.profiles where id = new.teacher_id for update;  -- one pick at a time per teacher
      if (select count(*) from public.profiles where teacher_id = new.teacher_id and id <> new.id) >= public.teacher_cap() then
        raise exception 'A teacher can have at most % students', public.teacher_cap();
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists teacher_cap on public.profiles;
create trigger teacher_cap before update of teacher_id on public.profiles for each row execute function public.check_teacher_cap();

-- Everyone a teacher can pick from: paid farmers who aren't teachers, with who already has them
create or replace function public.teacher_pick_list()
returns table (id uuid, full_name text, level smallint, day int, contractors bigint, last_active timestamptz, teacher_id uuid, teacher text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'teachers only'; end if;
  return query select p.id, coalesce(nullif(btrim(p.full_name), ''), p.email), p.level,
      floor(extract(epoch from now() - p.enrolled_at) / 86400)::int,
      (select count(*) from public.contractors c where c.farmer_id = p.id), public.last_active(p.id),
      public.teacher_of(p.id), public.ops_name(public.teacher_of(p.id))
    from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.verifier
    order by public.teacher_of(p.id) is not null, p.full_name;
end $$;

create or replace function public.pick_student(p_farmer uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s public.profiles; t public.profiles;
begin
  if not public.is_verifier() or public.is_admin() then raise exception 'teachers only'; end if;
  select * into t from public.profiles where id = auth.uid();
  select * into s from public.profiles where id = p_farmer for update;
  if s.id is null or s.role <> 'farmer' or not s.enrollment_paid then raise exception 'You can only pick a paid farmer'; end if;
  if s.verifier then raise exception 'Teachers can''t be students'; end if;
  if s.teacher_id = t.id then return; end if;
  if public.teacher_of(s.id) is not null then
    raise exception '% already has a teacher', coalesce(nullif(btrim(s.full_name), ''), s.email);
  end if;
  update public.profiles set teacher_id = t.id where id = s.id;  -- check_teacher_cap stops a 5th
  insert into public.notifications (farmer_id, body) values (s.id,
    coalesce(nullif(btrim(t.full_name), ''), 'A Lead Farming teacher') || ' is your teacher now. Your questions from the Learn page, your level-up requests and your 15 business models go to them.');
end $$;

create or replace function public.drop_student(p_farmer uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'teachers only'; end if;
  update public.profiles set teacher_id = null where id = p_farmer and (teacher_id = auth.uid() or public.is_admin());
  if not found then raise exception 'That farmer isn''t your student'; end if;
end $$;

-- Alex can still hand anyone to a teacher; same cap
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
      'Alex made you ' || coalesce(nullif(btrim(full_name), ''), email) || '''s teacher' || coalesce(' (' || phone || ')', '')
      || coalesce('. ' || why || '.', '.') || ' They are on your My students tab.'
      from public.profiles where id = farmer;
  end if;
end $$;

-- What a teacher sees: each student's last 2 weeks against the $1,000 goal. Alex sees every teacher.
create or replace function public.teacher_board() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - public.goal_window(); ts jsonb;
begin
  if not public.is_verifier() then raise exception 'teachers only'; end if;
  select coalesce(jsonb_agg(x order by x->>'full_name'), '[]') into ts from (
    select jsonb_build_object('id', t.id, 'full_name', coalesce(nullif(btrim(t.full_name), ''), t.email),
      'goal', public.student_goal() * public.teacher_cap(),
      'students', coalesce((select jsonb_agg(s order by s->>'full_name') from (
        select jsonb_build_object('id', p.id, 'full_name', coalesce(nullif(btrim(p.full_name), ''), p.email), 'email', p.email, 'phone', p.phone,
          'level', p.level, 'verifier', p.verifier, 'enrollment_paid', p.enrollment_paid, 'since', p.teacher_since,
          'day', floor(extract(epoch from now() - p.enrolled_at) / 86400)::int,
          'last_active', public.last_active(p.id), 'reasons', public.stuck_reasons(p.id),
          'contractors', (select count(*) from public.contractors c where c.farmer_id = p.id),
          'contractors_2wk', (select count(*) from public.contractors c where c.farmer_id = p.id and c.created_at >= since),
          'calls_2wk', (select count(*) from public.activities a where a.farmer_id = p.id and a.kind = 'call' and a.created_at >= since),
          'leads_2wk', (select count(*) from public.leads l where l.farmer_id = p.id and l.created_at >= since and l.status <> 'lost'),
          'pipeline_2wk', (select coalesce(sum(l.job_value), 0) from public.leads l where l.farmer_id = p.id and l.created_at >= since and l.status <> 'lost'),
          'closed_2wk', (select coalesce(sum(l.job_value), 0) from public.leads l where l.farmer_id = p.id and l.status = 'closed' and l.closed_at >= since),
          'fees_2wk', (select coalesce(sum(l.fee_amount), 0) from public.leads l where l.farmer_id = p.id and l.status = 'closed' and l.closed_at >= since),
          'waiting', (select count(*) from public.level_requests r where r.farmer_id = p.id and r.status = 'pending')
            + (select count(*) from public.teacher_questions q where q.farmer_id = p.id and q.answer is null)
            + (case when p.niche_submitted_at is not null and p.niche_approved_at is null and p.niche_note is null then 1 else 0 end)) s
        from public.profiles p where p.teacher_id = t.id) y), '[]')) x
    from public.profiles t where t.verifier and t.role <> 'admin' and (public.is_admin() or t.id = auth.uid())) z;
  return jsonb_build_object('since', since, 'days', extract(day from public.goal_window())::int, 'cap', public.teacher_cap(),
    'student_goal', public.student_goal(), 'teachers', ts);
end $$;

-- ---------- approvals go to the farmer's teacher ----------
drop function if exists public.review_queue();
create function public.review_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, to_level smallint, note text, files text[], created_at timestamptz, teacher text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select r.id, r.farmer_id, p.full_name, p.email, r.to_level, r.note, r.files, r.created_at, public.ops_name(public.teacher_of(p.id))
    from public.level_requests r join public.profiles p on p.id = r.farmer_id
    where r.status = 'pending' and public.teaches(r.farmer_id) order by public.teacher_of(p.id) is not null, r.created_at;
end $$;

drop function if exists public.question_queue();
create function public.question_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, quiz text, body text, created_at timestamptz, teacher text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select t.id, t.farmer_id, p.full_name, p.email, t.quiz, t.body, t.created_at, public.ops_name(public.teacher_of(p.id))
    from public.teacher_questions t join public.profiles p on p.id = t.farmer_id
    where t.answer is null and public.teaches(t.farmer_id) order by public.teacher_of(p.id) is not null, t.created_at;
end $$;

drop function if exists public.niche_queue();
create function public.niche_queue()
returns table (id uuid, full_name text, email text, niche text, niche_submitted_at timestamptz, teacher text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select p.id, p.full_name, p.email, p.niche, p.niche_submitted_at, public.ops_name(public.teacher_of(p.id)) from public.profiles p
    where p.niche_submitted_at is not null and p.niche_approved_at is null and p.niche_note is null and public.teaches(p.id)
    order by public.teacher_of(p.id) is not null, p.niche_submitted_at;
end $$;

-- refund packages: Alex only, since he sends the money back in Stripe
create or replace function public.refund_queue()
returns table (id uuid, farmer_id uuid, full_name text, email text, note text, files text[], progress jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  return query select r.id, r.farmer_id, p.full_name, p.email, r.note, r.files, r.progress, r.created_at
    from public.refund_requests r join public.profiles p on p.id = r.farmer_id where r.status = 'pending' and public.is_admin() order by r.created_at;
end $$;

create or replace function public.review_level_request(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.level_requests;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into r from public.level_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This request was already handled'; end if;
  if r.farmer_id = auth.uid() and not public.is_admin() then raise exception 'You can''t approve your own request'; end if;
  if not public.teaches(r.farmer_id) then raise exception 'Only their teacher or Alex can review this'; end if;
  update public.level_requests set status = case when p_approve then 'approved' else 'rejected' end,
    reviewer_id = auth.uid(), review_note = nullif(btrim(p_note), ''), reviewed_at = now() where id = p_id;
  if p_approve then update public.profiles set level = greatest(level, r.to_level) where id = r.farmer_id; end if;
end $$;

create or replace function public.answer_question(p_id uuid, p_answer text) returns void
language plpgsql security definer set search_path = public as $$
declare f uuid;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  if coalesce(btrim(p_answer), '') = '' then raise exception 'Write an answer first'; end if;
  select farmer_id into f from public.teacher_questions where id = p_id;
  if f is null then raise exception 'That question is gone'; end if;
  if not public.teaches(f) then raise exception 'Only their teacher or Alex can answer this'; end if;
  update public.teacher_questions set answer = btrim(p_answer), answered_by = auth.uid(), answered_at = now() where id = p_id;
end $$;

create or replace function public.review_niche(p_farmer uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  if p_farmer = auth.uid() and not public.is_admin() then raise exception 'You can''t approve your own list'; end if;
  if not public.teaches(p_farmer) then raise exception 'Only their teacher or Alex can review this'; end if;
  if p_approve then
    update public.profiles set niche_approved_at = now(), niche_note = null where id = p_farmer;
  else
    update public.profiles set niche_note = coalesce(nullif(btrim(p_note), ''), 'Sent back') where id = p_farmer;
  end if;
end $$;

create or replace function public.review_refund(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.refund_requests; po public.recruiter_payouts; who text;
begin
  if not public.is_admin() then raise exception 'Only Alex reviews refund packages'; end if;
  select * into r from public.refund_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This package was already handled'; end if;
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

-- What's on the signed-in reviewer's own list: a teacher's students, or for Alex everyone without a teacher
create or replace function public.my_waiting() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not public.is_verifier() then '{}'::jsonb else jsonb_build_object(
    'level_ups', (select count(*) from public.level_requests where status = 'pending' and public.mine_to_review(farmer_id)),
    'questions', (select count(*) from public.teacher_questions where answer is null and public.mine_to_review(farmer_id)),
    'niches', (select count(*) from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null and public.mine_to_review(id)),
    'refunds', (select count(*) from public.refund_requests where status = 'pending' and public.is_admin())) end;
$$;
create or replace function public.waiting_count() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(v::int) from jsonb_each_text(public.my_waiting()) e(k, v)), 0)::int;
$$;

-- A teacher can open their own students' full profile (history, Q&A); Alex can open anyone's
do $$ declare d text; a text := $x$if not public.is_admin() then raise exception 'admin only'; end if;$x$; begin
  d := pg_get_functiondef('public.farmer_history(uuid)'::regprocedure);
  if position(a in d) = 0 then raise exception 'farmer_history changed; update this migration'; end if;
  execute replace(d, a, $x$if not public.teaches(p_farmer) then raise exception 'admin only'; end if;$x$);
end $$;

-- The teacher's guide popup, shown once
create or replace function public.seen_teacher_guide() returns void
language sql security definer set search_path = public as $$
  update public.profiles set teacher_guide_seen = true, teacher_welcome_seen = true where id = auth.uid();
$$;

revoke execute on function public.teacher_of(uuid), public.teaches(uuid), public.mine_to_review(uuid), public.ops_name(uuid),
  public.check_teacher_cap() from public, anon, authenticated;
revoke execute on function public.teacher_pick_list(), public.pick_student(uuid), public.drop_student(uuid), public.teacher_board(),
  public.review_queue(), public.question_queue(), public.niche_queue(), public.my_waiting(), public.seen_teacher_guide() from public, anon;
grant execute on function public.teacher_pick_list(), public.pick_student(uuid), public.drop_student(uuid), public.teacher_board(),
  public.review_queue(), public.question_queue(), public.niche_queue(), public.my_waiting(), public.seen_teacher_guide() to authenticated;

-- The farmer's own teacher's name, for "Ask a teacher" on the Learn page
create or replace function public.my_teacher() returns text
language sql stable security definer set search_path = public as $$
  select public.ops_name(public.teacher_of(auth.uid()));
$$;
revoke execute on function public.my_teacher() from public, anon;
grant execute on function public.my_teacher() to authenticated;
