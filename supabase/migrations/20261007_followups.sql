-- Follow-up alerts, referral clawbacks and the reviewers' waiting count (approved by Alex 2026-10-07).

-- ---------- referral clawback ----------
-- An approved refund cancels an unpaid $250; a $250 already paid is marked as owed back to the Company.
alter table public.recruiter_payouts add column clawback_at timestamptz;          -- recruit refunded after the $250 was paid
alter table public.recruiter_payouts add column clawback_settled_at timestamptz;  -- repaid or deducted

-- ---------- in-portal alerts to a farmer ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
alter table public.notifications enable row level security;
create policy "own notifications" on public.notifications for select to authenticated using (farmer_id = auth.uid());
create policy "dismiss own notifications" on public.notifications for update to authenticated
  using (farmer_id = auth.uid()) with check (farmer_id = auth.uid());
revoke insert, update, delete on public.notifications from authenticated, anon;
grant update (read_at) on public.notifications to authenticated;

-- Approving a refund now also claws back the recruiter's $250 and tells them why
create or replace function public.review_refund(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.refund_requests; po public.recruiter_payouts; who text;
begin
  if not public.is_verifier() then raise exception 'verifiers only'; end if;
  select * into r from public.refund_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This package was already handled'; end if;
  if r.farmer_id = auth.uid() and not public.is_admin() then raise exception 'You can''t review your own package'; end if;
  update public.refund_requests set status = case when p_approve then 'approved' else 'denied' end,
    reviewer_id = auth.uid(), review_note = nullif(btrim(p_note), ''), reviewed_at = now() where id = p_id;
  if not p_approve then return; end if;
  select * into po from public.recruiter_payouts where recruit_id = r.farmer_id and status <> 'void' for update;
  if po.id is null then return; end if;
  select coalesce(nullif(btrim(full_name), ''), email) into who from public.profiles where id = r.farmer_id;
  if po.status = 'paid' then
    update public.recruiter_payouts set clawback_at = now() where id = po.id;
    insert into public.notifications (farmer_id, body) values (po.recruiter_id,
      who || ' got their enrollment refunded, so the $250 bonus you were paid for referring them is being clawed back. It comes out of your next bonus, or you repay it within 30 days.');
  else
    update public.recruiter_payouts set status = 'void' where id = po.id;
    insert into public.notifications (farmer_id, body) values (po.recruiter_id,
      who || ' got their enrollment refunded, so the $250 bonus for referring them is cancelled.');
  end if;
end $$;

-- The farmer's own referrals, with names (profiles are otherwise private)
create or replace function public.my_referrals()
returns table (full_name text, status text, amount numeric, created_at timestamptz, paid_at timestamptz, clawback_at timestamptz, clawback_settled_at timestamptz)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(p.full_name), ''), 'Your friend'), r.status, r.amount, r.created_at, r.paid_at, r.clawback_at, r.clawback_settled_at
  from public.recruiter_payouts r join public.profiles p on p.id = r.recruit_id
  where r.recruiter_id = auth.uid() and public.has_access() order by r.created_at desc;
$$;

-- How many things are waiting for a reviewer (the badge on the Approvals tab)
create or replace function public.waiting_count() returns int
language sql stable security definer set search_path = public as $$
  select case when not public.is_verifier() then 0 else (
    (select count(*) from public.level_requests where status = 'pending')
    + (select count(*) from public.teacher_questions where answer is null)
    + (select count(*) from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null)
    + (select count(*) from public.refund_requests where status = 'pending'))::int end;
$$;

revoke execute on function public.my_referrals(), public.waiting_count() from public, anon;
grant execute on function public.my_referrals(), public.waiting_count() to authenticated;
