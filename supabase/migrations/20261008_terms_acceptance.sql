-- Record which version of the Terms of Enrollment (leadfarminghq.com/terms/) each farmer agreed to before paying.
alter table public.profiles add column if not exists terms_version text;
alter table public.profiles add column if not exists terms_accepted_at timestamptz;

create or replace function public.accept_terms(p_version text) returns void
language sql security definer set search_path = public as $$
  update public.profiles set terms_version = p_version, terms_accepted_at = now() where id = auth.uid();
$$;
revoke execute on function public.accept_terms(text) from public, anon;
grant execute on function public.accept_terms(text) to authenticated;
