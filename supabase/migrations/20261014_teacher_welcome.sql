-- Teacher welcome popup (Alex, 2026-10-14): when Alex ticks a farmer as a verifier (a Lead Farming teacher),
-- they see a one-time popup from Alex the next time they open the portal. They set this themselves when they close it.
alter table public.profiles add column if not exists teacher_welcome_seen boolean not null default false;
grant update (teacher_welcome_seen) on public.profiles to authenticated;
