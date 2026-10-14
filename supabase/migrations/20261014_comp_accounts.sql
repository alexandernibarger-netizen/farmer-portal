-- Accurate money data (Alex, 2026-10-14): free (comp) accounts and bonuses that were never paid out in cash.
-- comp = the farmer has full access but never paid, so they don't count as revenue anywhere.
-- not_cash = a $250 bonus recorded as paid that was never paid in cash, so it doesn't count as money paid out.
alter table public.profiles add column if not exists comp boolean not null default false;
alter table public.recruiter_payouts add column if not exists not_cash boolean not null default false;

create or replace function public.set_comp(farmer uuid, on_off boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.profiles set comp = on_off where id = farmer;
end $$;
revoke execute on function public.set_comp(uuid, boolean) from public, anon;
grant execute on function public.set_comp(uuid, boolean) to authenticated;

create or replace view public.farmer_summary with (security_invoker = true) as
select p.id, p.full_name, p.email, p.enrollment_paid, p.recruited_by,
  (select count(*) from public.contractors c where c.farmer_id = p.id) as contractors,
  (select count(*) from public.contractors c where c.farmer_id = p.id and c.stage >= 3) as active_network,
  (select count(*) from public.leads l where l.farmer_id = p.id) as leads,
  (select count(*) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as leads_closed,
  (select coalesce(sum(fee_amount),0) from public.leads l where l.farmer_id = p.id and l.status = 'closed') as fees_earned,
  (select count(*) from public.recruiter_payouts r where r.recruiter_id = p.id) as recruits,
  p.level, p.verifier, p.enrollment_fee, p.comp
from public.profiles p where p.role = 'farmer';

-- Same dashboard as before, plus each farmer's comp flag; bonuses paid leave out the ones never paid in cash.
create or replace function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'farmers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'level', p.level, 'verifier', p.verifier,
        'paid', p.enrollment_paid, 'fee', p.enrollment_fee, 'comp', p.comp, 'created_at', p.created_at, 'enrolled_at', p.enrolled_at,
        'terms_version', p.terms_version, 'terms_declined_at', p.terms_declined_at,
        'last_active', (select max(t) from (
            select max(created_at) t from public.contractors where farmer_id = p.id
            union all select max(created_at) from public.leads where farmer_id = p.id
            union all select max(created_at) from public.activities where farmer_id = p.id
            union all select max(created_at) from public.upsells where farmer_id = p.id
            union all select max(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = p.id) x),
        'progress', case when p.enrollment_paid and p.enrolled_at is not null then public.refund_progress(p.id) end)
      order by p.created_at) from public.profiles p where p.role = 'farmer'), '[]'),
    'work', jsonb_build_object(
      'contractors', (select count(*) from public.contractors),
      'agreed', (select count(*) from public.contractors where stage >= 3),
      'calls', (select count(*) from public.activities where kind = 'call'),
      'comments', (select coalesce(sum(count), 0) from public.activities where kind = 'comments'),
      'leads_sent', (select count(*) from public.leads where direction = 'outbound'),
      'leads_closed', (select count(*) from public.leads where status = 'closed'),
      'fees_earned', (select coalesce(sum(fee_amount), 0) from public.leads where status = 'closed'),
      'fees_collected', (select coalesce(sum(fee_amount), 0) from public.leads where status = 'closed' and fee_paid),
      'upsells_closed', (select count(*) from public.upsells where status = 'closed'),
      'upsell_revenue', (select coalesce(sum(amount), 0) from public.upsells where status = 'closed')),
    'money', jsonb_build_object(
      'bonuses_owed', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'owed'),
      'bonuses_pending', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'pending'),
      'bonuses_paid', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'paid' and clawback_at is null and not not_cash),
      'bonuses_not_cash', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'paid' and not_cash),
      'clawbacks_open', (select coalesce(sum(amount), 0) from public.recruiter_payouts where clawback_at is not null and clawback_settled_at is null),
      'refunds_approved', (select count(*) from public.refund_requests where status = 'approved'),
      'refunded', (select coalesce(sum((progress->>'refund_amount')::numeric), 0) from public.refund_requests where status = 'approved')),
    'waiting', jsonb_build_object(
      'level_ups', (select count(*) from public.level_requests where status = 'pending'),
      'questions', (select count(*) from public.teacher_questions where answer is null),
      'niches', (select count(*) from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null),
      'refunds', (select count(*) from public.refund_requests where status = 'pending')));
end $$;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;

-- Monday report: comp accounts aren't revenue, and bonuses never paid in cash aren't commissions paid.
create or replace function ops.weekly_report() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  t1 timestamptz := now(); t0 timestamptz := now() - interval '7 days';
  rev numeric; paid_n int; comm numeric; owed numeric; refunds int;
  rev_all numeric; comm_all numeric; farmers_all int;
  signups int; contractors_new int; contractors_all int;
  leads_sent int; leads_closed int; fees numeric; upsells_n int; upsells_amt numeric; levelups int;
  w_levels int; w_questions int; w_niches int; w_refunds int;
begin
  select count(*), sum(enrollment_fee) into paid_n, rev from public.profiles
    where enrollment_paid and not comp and enrolled_at >= t0 and enrolled_at < t1;
  select sum(amount) into comm from public.recruiter_payouts where status = 'paid' and not not_cash and paid_at >= t0 and paid_at < t1;
  select sum(amount) into owed from public.recruiter_payouts where status = 'owed';
  select count(*) into refunds from public.refund_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select sum(enrollment_fee), count(*) into rev_all, farmers_all from public.profiles where enrollment_paid and not comp and role = 'farmer';
  select sum(amount) into comm_all from public.recruiter_payouts where status = 'paid' and not not_cash;
  select count(*) into signups from public.profiles where role = 'farmer' and created_at >= t0 and created_at < t1;
  select count(*) filter (where created_at >= t0 and created_at < t1), count(*) into contractors_new, contractors_all from public.contractors;
  select count(*) into leads_sent from public.leads where direction = 'outbound' and created_at >= t0 and created_at < t1;
  select count(*) into leads_closed from public.leads where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select sum(fee_amount) into fees from public.leads where fee_paid and fee_paid_at >= t0 and fee_paid_at < t1;
  select count(*), sum(amount) into upsells_n, upsells_amt from public.upsells where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select count(*) into levelups from public.level_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select count(*) into w_levels from public.level_requests where status = 'pending';
  select count(*) into w_questions from public.teacher_questions where answer is null;
  select count(*) into w_niches from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null;
  select count(*) into w_refunds from public.refund_requests where status = 'pending';

  return '📊 Weekly report: ' || to_char(t0 at time zone 'America/Chicago', 'Mon DD') || ' to '
    || to_char(t1 at time zone 'America/Chicago', 'Mon DD') || E'\n\n'
    || E'💰 Money (this week)\n'
    || 'Enrollments: ' || paid_n || ' paid, ' || ops.money(rev) || E' collected (before Stripe fees)\n'
    || 'Commissions paid out: ' || ops.money(comm) || E'\n'
    || 'Net: ' || ops.money(coalesce(rev, 0) - coalesce(comm, 0)) || E'\n'
    || 'Refunds approved: ' || refunds || E'\n'
    || 'Commissions still owed: ' || ops.money(owed) || E'\n\n'
    || E'📈 Growth (this week)\n'
    || 'New signups: ' || signups || E'\n'
    || 'New contractors added: ' || contractors_new || E'\n'
    || 'Leads sent: ' || leads_sent || ', closed: ' || leads_closed || E'\n'
    || 'Referral fees farmers collected: ' || ops.money(fees) || E'\n'
    || 'Upsells closed: ' || upsells_n || ' (' || ops.money(upsells_amt) || E')\n'
    || 'Level-ups approved: ' || levelups || E'\n\n'
    || E'🏦 All time\n'
    || 'Paid farmers: ' || farmers_all || E'\n'
    || 'Revenue: ' || ops.money(rev_all) || ', commissions paid: ' || ops.money(comm_all)
    || ', net: ' || ops.money(coalesce(rev_all, 0) - coalesce(comm_all, 0)) || E'\n'
    || 'Contractors in the system: ' || contractors_all || E'\n\n'
    || E'⏳ Waiting on you\n'
    || 'Level-up requests: ' || w_levels || ', questions: ' || w_questions
    || ', niches: ' || w_niches || ', refunds: ' || w_refunds || E'\n'
    || 'https://leadfarminghq.com';
end;
$$;
revoke execute on function ops.weekly_report() from public, anon, authenticated;
