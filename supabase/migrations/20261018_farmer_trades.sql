-- Farmers add their own trades (contractor niches). farmer_id null = a shared trade Alex manages in the
-- Trades tab; farmer_id set = that farmer's own trade, seen and used only by them (and admins).
alter table public.trades add column if not exists farmer_id uuid references public.profiles(id) on delete cascade;
alter table public.trades drop constraint if exists trades_name_key;
-- one name per owner (shared list counts as one owner), case-insensitive
create unique index if not exists trades_owner_name on public.trades
  (coalesce(farmer_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)));
-- and a farmer can't add a copy of a shared trade
create or replace function public.trades_check() returns trigger language plpgsql set search_path = public as $$
begin
  new.name := btrim(new.name);
  if new.name = '' then raise exception 'Give the trade a name'; end if;
  if new.farmer_id is not null and exists (select 1 from public.trades t where t.farmer_id is null and lower(t.name) = lower(new.name)) then
    raise exception '% is already on the shared list', new.name;
  end if;
  return new;
end $$;
drop trigger if exists trades_check on public.trades;
create trigger trades_check before insert or update on public.trades for each row execute function public.trades_check();

alter policy "read trades" on public.trades using (public.has_access() and (farmer_id is null or farmer_id = auth.uid()));
drop policy if exists "own trades" on public.trades;
create policy "own trades" on public.trades for all to authenticated
  using (farmer_id = auth.uid() and public.has_access())
  with check (farmer_id = auth.uid() and public.has_access());
grant insert, update, delete on public.trades to authenticated;
grant usage on sequence public.trades_id_seq to authenticated;

-- a contractor can only be filed under a shared trade or its own farmer's trade
create or replace function public.contractor_trade_check() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.trade_id is not null and exists (select 1 from public.trades t where t.id = new.trade_id
      and t.farmer_id is not null and t.farmer_id <> new.farmer_id) then
    raise exception 'That trade belongs to another farmer';
  end if;
  return new;
end $$;
drop trigger if exists contractor_trade_check on public.contractors;
create trigger contractor_trade_check before insert or update of trade_id, farmer_id on public.contractors
  for each row execute function public.contractor_trade_check();
