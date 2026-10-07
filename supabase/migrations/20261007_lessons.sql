-- Lessons and must-ace quizzes. A farmer only receives the lessons and quizzes of levels they've reached.
-- Quiz answers never leave the database: submit_quiz grades on the server.
-- The lesson and quiz rows are NOT in this repo (they contain the answer key); they're seeded from the
-- project files (curriculum/lessons/seed.sql). Pictures are drawn by curriculum/diagrams.js.
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

