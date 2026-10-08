-- ---------- admin dashboard (20261008_admin_dashboard.sql) ----------
-- Everything Alex's Home screen shows, counted in the database so totals aren't cut off at the API's row limit.
create or replace function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'farmers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'full_name', p.full_name, 'email', p.email, 'level', p.level, 'verifier', p.verifier,
        'paid', p.enrollment_paid, 'fee', p.enrollment_fee, 'created_at', p.created_at, 'enrolled_at', p.enrolled_at,
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
      'bonuses_paid', (select coalesce(sum(amount), 0) from public.recruiter_payouts where status = 'paid' and clawback_at is null),
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
