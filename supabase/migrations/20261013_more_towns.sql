-- Farmers can add more towns to their farmland: raise the cap from 10 to 50.
alter table public.profiles drop constraint if exists profiles_towns_check;
alter table public.profiles add constraint profiles_towns_check check (cardinality(towns) <= 50);
