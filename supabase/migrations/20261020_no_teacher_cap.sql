-- ---------- no cap on teacher students (20261020_no_teacher_cap.sql) ----------
-- Alex, 2026-10-20: "remove the limit of 4 students each." Teachers can pick as many students as they want.
-- The teacher_cap trigger stays (it also stamps teacher_since); its function just no longer counts students.
-- Replaced rather than dropped because DROP statements hang in the Supabase MCP.

create or replace function public.teacher_cap() returns int language sql immutable as 'select null::int';  -- no cap

create or replace function public.check_teacher_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.teacher_id is distinct from old.teacher_id then
    new.teacher_since := case when new.teacher_id is null then null else now() end;
  end if;
  return new;
end $$;

-- What a teacher sees: each student's last 2 weeks against the $1,000 goal. Alex sees every teacher.
-- A teacher's goal is $1,000 times however many students they have.
create or replace function public.teacher_board() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - public.goal_window(); ts jsonb;
begin
  if not public.is_verifier() then raise exception 'teachers only'; end if;
  select coalesce(jsonb_agg(x order by x->>'full_name'), '[]') into ts from (
    select jsonb_build_object('id', t.id, 'full_name', coalesce(nullif(btrim(t.full_name), ''), t.email),
      'goal', public.student_goal() * (select count(*) from public.profiles p where p.teacher_id = t.id),
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
  return jsonb_build_object('since', since, 'days', extract(day from public.goal_window())::int, 'cap', null,
    'student_goal', public.student_goal(), 'teachers', ts);
end $$;
