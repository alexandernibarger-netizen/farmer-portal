-- My farmland: each farmer's 50-mile area map. towns[1] is the home base, then up to 9 more towns.
-- Each contractor is tagged with one of the farmer's 15 niches; its city is the town it covers.
alter table public.profiles add column if not exists towns text[] not null default '{}'
  check (cardinality(towns) <= 10);
grant update (towns) on public.profiles to authenticated;
alter table public.contractors add column if not exists niche text;
