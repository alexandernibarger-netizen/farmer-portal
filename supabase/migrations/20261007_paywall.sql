-- Paywall: farmers can't read or write any program data until their $500 enrollment is paid.
-- Their own profile stays readable so the portal can show the Pay $500 screen.
-- Applied to the live project 2026-10-07 as migration "paywall".
create or replace function public.has_access() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and (enrollment_paid or role = 'admin'));
$$;
revoke execute on function public.has_access() from public, anon;
grant execute on function public.has_access() to authenticated;

alter policy "read stages" on public.stages using (public.has_access());
alter policy "read trades" on public.trades using (public.has_access());
alter policy "payouts read" on public.recruiter_payouts
  using ((recruiter_id = auth.uid() and public.has_access()) or public.is_admin());
alter policy "own contractors" on public.contractors
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());
alter policy "own history" on public.contractor_stage_history
  using (exists (select 1 from public.contractors c where c.id = contractor_id
    and ((c.farmer_id = auth.uid() and public.has_access()) or public.is_admin())));
alter policy "own leads" on public.leads
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());
alter policy "own upsells" on public.upsells
  using ((farmer_id = auth.uid() and public.has_access()) or public.is_admin())
  with check ((farmer_id = auth.uid() and public.has_access()) or public.is_admin());
