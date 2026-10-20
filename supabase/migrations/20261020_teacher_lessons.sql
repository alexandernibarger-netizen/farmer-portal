-- ---------- teacher lessons (20261020_teacher_lessons.sql) ----------
-- Alex, 2026-10-20: a teacher can have their own lesson that only their students see, outside the main curriculum.
-- First one: Vincent Beck's "Cold Calling & Confidence" class (his 17-slide deck), shown on Learn as "Teacher lesson".
-- Vincent runs it live from My students (Start class / Next slide); his students follow along, do the challenge,
-- log their practice numbers and send role-play feedback.

-- One row per teacher who has a lesson. live/slide is what they're presenting right now.
create table if not exists public.teacher_classes (
  teacher_id uuid primary key references public.profiles(id) on delete cascade,
  lesson text not null default 'call-confidence',
  live boolean not null default false,
  slide smallint not null default 1 check (slide between 1 and 17),
  pairs jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.teacher_classes enable row level security;
drop policy if exists "read own class" on public.teacher_classes;
create policy "read own class" on public.teacher_classes for select to authenticated
  using (teacher_id = auth.uid() or public.is_admin());  -- students get theirs through my_class()

-- A student's progress through their teacher's lesson (parts read, challenge ticks, practice numbers)
create table if not exists public.class_progress (
  farmer_id uuid primary key references public.profiles(id) on delete cascade,
  lesson text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.class_progress enable row level security;
drop policy if exists "read class progress" on public.class_progress;
create policy "read class progress" on public.class_progress for select to authenticated
  using (farmer_id = auth.uid() or public.is_admin());  -- teachers get their students' through teacher_class()

-- Role-play feedback and the closing discussion answer
create table if not exists public.class_feedback (
  id bigserial primary key,
  from_id uuid not null references public.profiles(id) on delete cascade,
  to_id uuid references public.profiles(id) on delete set null,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('roleplay', 'discussion')),
  round smallint,
  well text,
  improve text,
  created_at timestamptz not null default now()
);
alter table public.class_feedback enable row level security;
drop policy if exists "read class feedback" on public.class_feedback;
create policy "read class feedback" on public.class_feedback for select to authenticated
  using (from_id = auth.uid() or to_id = auth.uid() or teacher_id = auth.uid() or public.is_admin());

-- The student's side: their teacher's class, what's live, their partner and their own progress. Null when they have none.
create or replace function public.my_class() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lesson', c.lesson, 'teacher', public.ops_name(c.teacher_id), 'live', c.live, 'slide', c.slide,
    'partner', (select public.ops_name(case when (p->>0)::uuid = auth.uid() then (p->>1)::uuid else (p->>0)::uuid end)
                from jsonb_array_elements(c.pairs) p where p ? auth.uid()::text limit 1),
    'partner_id', (select case when (p->>0)::uuid = auth.uid() then p->>1 else p->>0 end
                from jsonb_array_elements(c.pairs) p where p ? auth.uid()::text limit 1),
    'data', coalesce((select data from public.class_progress where farmer_id = auth.uid()), '{}'::jsonb))
  from public.teacher_classes c where c.teacher_id = public.teacher_of(auth.uid());
$$;

create or replace function public.class_save(p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare l text;
begin
  select lesson into l from public.teacher_classes where teacher_id = public.teacher_of(auth.uid());
  if l is null then raise exception 'Your teacher has no lesson for you yet'; end if;
  if pg_column_size(p_data) > 8000 then raise exception 'Too much data'; end if;
  insert into public.class_progress (farmer_id, lesson, data) values (auth.uid(), l, p_data)
  on conflict (farmer_id) do update set data = excluded.data, lesson = excluded.lesson, updated_at = now();
end $$;

create or replace function public.class_feedback_send(p_kind text, p_round smallint, p_well text, p_improve text, p_to uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := public.teacher_of(auth.uid());
begin
  if t is null or not exists (select 1 from public.teacher_classes where teacher_id = t) then raise exception 'Your teacher has no lesson for you yet'; end if;
  if coalesce(btrim(p_well), '') = '' and coalesce(btrim(p_improve), '') = '' then raise exception 'Write something first'; end if;
  if p_to is not null and public.teacher_of(p_to) is distinct from t then p_to := null; end if;
  insert into public.class_feedback (from_id, to_id, teacher_id, kind, round, well, improve)
  values (auth.uid(), p_to, t, p_kind, p_round, left(p_well, 1000), left(p_improve, 1000));
end $$;

-- The teacher's side: the live state, each student's progress, and the latest feedback. Null when they have no lesson.
create or replace function public.teacher_class() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('lesson', c.lesson, 'live', c.live, 'slide', c.slide, 'pairs', c.pairs,
    'students', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', public.ops_name(p.id),
        'data', coalesce(cp.data, '{}'::jsonb), 'updated_at', cp.updated_at) order by p.full_name)
      from public.profiles p left join public.class_progress cp on cp.farmer_id = p.id
      where p.teacher_id = c.teacher_id), '[]'::jsonb),
    'feedback', coalesce((select jsonb_agg(f order by f.created_at desc) from (
        select f.id, f.kind, f.round, f.well, f.improve, f.created_at, public.ops_name(f.from_id) as from_name, public.ops_name(f.to_id) as to_name
        from public.class_feedback f where f.teacher_id = c.teacher_id order by f.created_at desc limit 12) f), '[]'::jsonb))
  from public.teacher_classes c where c.teacher_id = auth.uid();
$$;

create or replace function public.class_control(p_live boolean, p_slide smallint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.teacher_classes set live = p_live, slide = greatest(1, least(17, p_slide)), updated_at = now() where teacher_id = auth.uid();
  if not found then raise exception 'You have no teacher lesson'; end if;
end $$;

-- Pair the teacher's students at random (an odd one out pairs with the teacher)
create or replace function public.class_shuffle_pairs() returns void
language plpgsql security definer set search_path = public as $$
declare ids uuid[]; pr jsonb := '[]'::jsonb; i int := 1;
begin
  if not exists (select 1 from public.teacher_classes where teacher_id = auth.uid()) then raise exception 'You have no teacher lesson'; end if;
  select array_agg(id order by random()) into ids from public.profiles where teacher_id = auth.uid();
  while ids is not null and i <= array_length(ids, 1) loop
    pr := pr || jsonb_build_array(jsonb_build_array(ids[i], coalesce(ids[i + 1], auth.uid())));
    i := i + 2;
  end loop;
  update public.teacher_classes set pairs = pr, updated_at = now() where teacher_id = auth.uid();
end $$;

revoke execute on function public.my_class(), public.class_save(jsonb), public.class_feedback_send(text, smallint, text, text, uuid),
  public.teacher_class(), public.class_control(boolean, smallint), public.class_shuffle_pairs() from public, anon;
grant execute on function public.my_class(), public.class_save(jsonb), public.class_feedback_send(text, smallint, text, text, uuid),
  public.teacher_class(), public.class_control(boolean, smallint), public.class_shuffle_pairs() to authenticated;

-- Vincent Beck's class
insert into public.teacher_classes (teacher_id, lesson)
select id, 'call-confidence' from public.profiles where full_name = 'Vincent Beck' and verifier
on conflict (teacher_id) do nothing;
