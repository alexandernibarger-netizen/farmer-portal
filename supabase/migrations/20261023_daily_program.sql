-- ---------- Julian's Daily Program (20261023_daily_program.sql) ----------
-- Alex, 2026-10-23: Julian Nibarger gets his own teacher lesson ("The Daily Program", curriculum/daily-program.js),
-- an accountability checklist of his promises on My students (Alex sees it on Teachers), and his students
-- send him their numbers every night. Days run on Texas time; day 1 is the day Julian ticks his kickoff call.

create or replace function public.texas_today() returns date
language sql stable set search_path = public as $$ select (now() at time zone 'America/Chicago')::date $$;

-- The day the 8 days started (Julian's kickoff call)
alter table public.teacher_classes add column if not exists started_on date;

-- A teacher's ticked promises, one row per item per Texas day. Items are the keys in the lesson file
-- (collect, review, crm, behind, stepin, groupcall, teach, kickoff, wrap, oneonone), plus got:<student> when a
-- student texted their numbers instead of sending them here.
create table if not exists public.teacher_promises (
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  item text not null check (item ~ '^[a-z0-9:-]{1,60}$'),
  done_at timestamptz not null default now(),
  primary key (teacher_id, day, item)
);
alter table public.teacher_promises enable row level security;
create policy "read own promises" on public.teacher_promises for select to authenticated
  using (teacher_id = auth.uid() or public.is_admin());

-- A student's nightly numbers, one row per Texas day
create table if not exists public.class_numbers (
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  conv int not null default 0 check (conv between 0 and 1000),
  conf int not null default 0 check (conf between 0 and 1000),
  leads int not null default 0 check (leads between 0 and 1000),
  sent int not null default 0 check (sent between 0 and 1000),
  est int not null default 0 check (est between 0 and 1000),
  in_crm boolean not null default false,
  stuck text,
  updated_at timestamptz not null default now(),
  primary key (farmer_id, day)
);
alter table public.class_numbers enable row level security;
create policy "read class numbers" on public.class_numbers for select to authenticated
  using (farmer_id = auth.uid() or public.is_admin());  -- teachers get their students' through daily_board()

-- The one clear next action a teacher sends a student who is falling behind
create table if not exists public.class_actions (
  id bigserial primary key,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);
alter table public.class_actions enable row level security;
create policy "read class actions" on public.class_actions for select to authenticated
  using (farmer_id = auth.uid() or teacher_id = auth.uid() or public.is_admin());

-- The student's side, now with the program day, tonight's numbers and the teacher's latest action
create or replace function public.my_class() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lesson', c.lesson, 'teacher', public.ops_name(c.teacher_id), 'live', c.live, 'slide', c.slide,
    'partner', (select public.ops_name(case when (p->>0)::uuid = auth.uid() then (p->>1)::uuid else (p->>0)::uuid end)
                from jsonb_array_elements(c.pairs) p where p ? auth.uid()::text limit 1),
    'partner_id', (select case when (p->>0)::uuid = auth.uid() then p->>1 else p->>0 end
                from jsonb_array_elements(c.pairs) p where p ? auth.uid()::text limit 1),
    'data', coalesce((select data from public.class_progress where farmer_id = auth.uid()), '{}'::jsonb),
    'today', public.texas_today(),
    'day', case when c.started_on is not null then public.texas_today() - c.started_on + 1 end,
    'numbers', (select to_jsonb(n) - 'farmer_id' from public.class_numbers n where n.farmer_id = auth.uid() and n.day = public.texas_today()),
    'action', (select jsonb_build_object('body', a.body, 'at', a.created_at) from public.class_actions a
               where a.farmer_id = auth.uid() and a.teacher_id = c.teacher_id order by a.created_at desc limit 1))
  from public.teacher_classes c where c.teacher_id = public.teacher_of(auth.uid());
$$;

create or replace function public.class_numbers_send(p_conv int, p_conf int, p_leads int, p_sent int, p_est int, p_in_crm boolean, p_stuck text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.teacher_classes where teacher_id = public.teacher_of(auth.uid())) then
    raise exception 'Your teacher has no lesson for you yet';
  end if;
  insert into public.class_numbers (farmer_id, day, conv, conf, leads, sent, est, in_crm, stuck)
  values (auth.uid(), public.texas_today(), greatest(0, coalesce(p_conv, 0)), greatest(0, coalesce(p_conf, 0)), greatest(0, coalesce(p_leads, 0)),
    greatest(0, coalesce(p_sent, 0)), greatest(0, coalesce(p_est, 0)), coalesce(p_in_crm, false), left(nullif(btrim(p_stuck), ''), 1000))
  on conflict (farmer_id, day) do update set conv = excluded.conv, conf = excluded.conf, leads = excluded.leads, sent = excluded.sent,
    est = excluded.est, in_crm = excluded.in_crm, stuck = excluded.stuck, updated_at = now();
end $$;

create or replace function public.class_action_send(p_farmer uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.teacher_of(p_farmer) is distinct from auth.uid() then raise exception 'Only their teacher can send this'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'Write the action first'; end if;
  insert into public.class_actions (teacher_id, farmer_id, body) values (auth.uid(), p_farmer, left(btrim(p_body), 1000));
end $$;

-- Tick or untick one of the teacher's promises for today. Ticking the kickoff starts day 1.
create or replace function public.promise_set(p_item text, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t date := public.texas_today();
begin
  if not exists (select 1 from public.teacher_classes where teacher_id = auth.uid()) then raise exception 'You have no teacher lesson'; end if;
  if p_on then
    insert into public.teacher_promises (teacher_id, day, item) values (auth.uid(), t, p_item) on conflict do nothing;
    if p_item = 'kickoff' then update public.teacher_classes set started_on = t where teacher_id = auth.uid(); end if;
  else
    delete from public.teacher_promises where teacher_id = auth.uid() and day = t and item = p_item;
    if p_item = 'kickoff' then update public.teacher_classes set started_on = null where teacher_id = auth.uid() and started_on = t; end if;
  end if;
end $$;

-- The teacher's checklist and one sheet (the teacher, or Alex looking at a teacher)
create or replace function public.daily_board(p_teacher uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tid uuid := coalesce(p_teacher, auth.uid()); c public.teacher_classes; t date := public.texas_today();
begin
  if tid <> auth.uid() and not public.is_admin() then raise exception 'Only the teacher or Alex can see this'; end if;
  select * into c from public.teacher_classes where teacher_id = tid;
  if c.teacher_id is null then return null; end if;
  return jsonb_build_object(
    'lesson', c.lesson, 'teacher', public.ops_name(tid), 'today', t, 'started_on', c.started_on,
    'day', case when c.started_on is not null then t - c.started_on + 1 end,
    'promises', coalesce((select jsonb_agg(jsonb_build_object('day', p.day, 'item', p.item) order by p.day)
      from public.teacher_promises p where p.teacher_id = tid and p.day >= coalesce(c.started_on, t)), '[]'::jsonb),
    'students', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', public.ops_name(s.id),
        'why', (cp.data->'why') is not null,
        'numbers', (select to_jsonb(n) - 'farmer_id' from public.class_numbers n where n.farmer_id = s.id and n.day = t),
        'fees', (select coalesce(sum(l.fee_amount), 0) from public.leads l where l.farmer_id = s.id and l.status = 'closed'
                 and l.closed_at >= ((coalesce(c.started_on, t))::timestamp at time zone 'America/Chicago')),
        'action', (select jsonb_build_object('body', a.body, 'at', a.created_at) from public.class_actions a
                   where a.farmer_id = s.id and a.teacher_id = tid order by a.created_at desc limit 1)) order by s.full_name)
      from public.profiles s left join public.class_progress cp on cp.farmer_id = s.id
      where s.teacher_id = tid), '[]'::jsonb));
end $$;

revoke execute on function public.texas_today(), public.class_numbers_send(int, int, int, int, int, boolean, text), public.class_action_send(uuid, text),
  public.promise_set(text, boolean), public.daily_board(uuid) from public, anon;
grant execute on function public.texas_today(), public.class_numbers_send(int, int, int, int, int, boolean, text), public.class_action_send(uuid, text),
  public.promise_set(text, boolean), public.daily_board(uuid) to authenticated;

-- Julian Nibarger's class
insert into public.teacher_classes (teacher_id, lesson)
select id, 'daily-program' from public.profiles where full_name = 'Julian Nibarger' and verifier
on conflict (teacher_id) do nothing;
