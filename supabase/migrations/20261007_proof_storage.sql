-- Private bucket for level-up proof. Farmers upload into a folder named by their user id.
insert into storage.buckets (id, name, public, file_size_limit)
values ('proof', 'proof', false, 10485760) on conflict (id) do nothing;
create policy "proof upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'proof' and (storage.foldername(name))[1] = auth.uid()::text and public.has_access());
create policy "proof read own or verifier" on storage.objects for select to authenticated
  using (bucket_id = 'proof' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_verifier()));
