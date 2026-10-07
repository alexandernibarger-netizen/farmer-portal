-- Welcome-back greetings on Home, edited by Alex in the Welcome tab. {name} becomes the farmer's first name.
create table public.welcome_lines (
  id serial primary key,
  body text not null check (length(btrim(body)) between 1 and 300),
  created_at timestamptz not null default now()
);
alter table public.welcome_lines enable row level security;
create policy "read welcome lines" on public.welcome_lines for select to authenticated using (public.has_access());
create policy "admin welcome lines" on public.welcome_lines for all to authenticated using (public.is_admin()) with check (public.is_admin());
