-- First-login tour: the highest level whose portal tour the farmer has seen (0 = never toured).
-- Farmers set it themselves when they finish or skip a tour.
alter table public.profiles add column if not exists tour_level smallint not null default 0;
grant update (tour_level) on public.profiles to authenticated;
