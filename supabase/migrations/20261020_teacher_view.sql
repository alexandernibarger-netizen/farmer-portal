-- Teachers (verifiers) read every level's lessons so they can teach students who are ahead of them.
drop policy if exists "read quizzes" on public.quizzes;
create policy "read quizzes" on public.quizzes for select to authenticated
  using (public.has_access() and (level <= public.my_level() or public.is_verifier()));
drop policy if exists "read lessons" on public.lessons;
create policy "read lessons" on public.lessons for select to authenticated
  using (public.has_access() and (public.is_verifier() or exists (select 1 from public.quizzes z where z.key = quiz and z.level <= public.my_level())));

-- Teachers get the whole CRM (every stage, leads, upsells) so they can farm alongside their students.
create or replace function public.my_level() returns smallint
language sql stable security definer set search_path = public as $$
  select case when role = 'admin' or verifier then 3::smallint else level end from public.profiles where id = auth.uid();
$$;
