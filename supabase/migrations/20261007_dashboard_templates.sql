-- Each person picks a dashboard look in Settings. 'farm' is the default Duolingo-style look.
alter table public.profiles add column if not exists dashboard_template text not null default 'farm'
  check (dashboard_template in ('farm', 'clean', 'nightbarn', 'sunrise', 'almanac'));
grant update (dashboard_template) on public.profiles to authenticated;
