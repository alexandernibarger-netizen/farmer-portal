-- Monday report additions (Alex, 2026-10-14): real revenue (comp accounts left out), new paid this week,
-- booked calls and show rate, where buyers came from, ad spend against the $3,750 budget, sales and cost per
-- sale from ads, leads sent, first fees, and inactive farmers. Ad spend is typed in by Alex on Home.

create table if not exists public.ad_spend (
  id bigint generated always as identity primary key,
  spent_on date not null,
  amount numeric(10, 2) not null check (amount > 0 and amount < 100000),
  note text check (length(note) <= 200),
  created_at timestamptz not null default now());
alter table public.ad_spend enable row level security;
create policy "ad spend admin" on public.ad_spend for all using (public.is_admin()) with check (public.is_admin());

-- The 2026 ad budget, in 3 stages ($3,750 in all)
create or replace function public.ad_stages() returns table (stage text, starts date, ends date, budget numeric)
language sql immutable as $$
  values ('Stage 1', date '2026-11-01', date '2026-11-14', 500::numeric),
         ('Stage 2', date '2026-11-15', date '2026-11-30', 1250::numeric),
         ('Stage 3', date '2026-12-01', date '2026-12-24', 2000::numeric);
$$;

-- Admin Home "Ads" card: spend by stage, sales from ads, cost per sale, every entry
create or replace function public.ad_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare spent numeric; sales int;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select coalesce(sum(amount), 0) into spent from public.ad_spend;
  select count(*) into sales from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp and public.source_of(p) = 'Meta ads';
  return jsonb_build_object(
    'stages', (select jsonb_agg(jsonb_build_object('stage', s.stage, 'starts', s.starts, 'ends', s.ends, 'budget', s.budget,
        'spent', (select coalesce(sum(a.amount), 0) from public.ad_spend a where a.spent_on between s.starts and s.ends)) order by s.starts)
      from public.ad_stages() s),
    'spent', spent, 'budget', (select sum(budget) from public.ad_stages()),
    'sales', sales, 'cost_per_sale', case when sales > 0 then round(spent / sales, 2) end,
    'entries', coalesce((select jsonb_agg(to_jsonb(a) order by a.spent_on desc, a.id desc) from public.ad_spend a), '[]'));
end $$;
revoke execute on function public.ad_summary() from public, anon;
grant execute on function public.ad_summary() to authenticated;

-- The Monday report (Telegram), covering the 7 days before it runs
create or replace function ops.weekly_report() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  t1 timestamptz := now(); t0 timestamptz := now() - interval '7 days';
  rev numeric; paid_n int; new_names text; comm numeric; owed numeric; refunds int;
  rev_all numeric; comm_all numeric; farmers_all int; comps int;
  signups int; contractors_new int; leads_sent int; leads_closed int; fees numeric; first_fees text; levelups int;
  booked int; held int; showed int; no_show int; from_calls int; requests int;
  src_week text; src_all text;
  spend_week numeric; spend_all numeric; ad_sales_week int; ad_sales_all int; stage_line text;
  inactive text; inactive_n int;
  w_levels int; w_questions int; w_niches int; w_refunds int;
  goal numeric := 30000; days_left int := greatest(0, date '2026-12-31' - (now() at time zone 'America/Chicago')::date);
begin
  -- money: only farmers who actually paid
  select count(*), sum(enrollment_fee), string_agg(coalesce(nullif(btrim(full_name), ''), email), ', ' order by enrolled_at)
    into paid_n, rev, new_names from public.profiles
    where role = 'farmer' and enrollment_paid and not comp and enrolled_at >= t0 and enrolled_at < t1;
  select sum(enrollment_fee), count(*) into rev_all, farmers_all from public.profiles where role = 'farmer' and enrollment_paid and not comp;
  select count(*) into comps from public.profiles where role = 'farmer' and enrollment_paid and comp;
  select sum(amount) into comm from public.recruiter_payouts where status = 'paid' and not not_cash and paid_at >= t0 and paid_at < t1;
  select sum(amount) into comm_all from public.recruiter_payouts where status = 'paid' and not not_cash;
  select sum(amount) into owed from public.recruiter_payouts where status = 'owed';
  select count(*) into refunds from public.refund_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;

  -- calls with Alex
  select count(*) into requests from public.call_requests where created_at >= t0 and created_at < t1;
  select count(*) into booked from public.call_requests where booked_at >= t0 and booked_at < t1;
  select count(*) filter (where status in ('showed', 'no_show', 'enrolled', 'booked')), count(*) filter (where status in ('showed', 'enrolled')),
         count(*) filter (where status = 'no_show')
    into held, showed, no_show from public.call_requests where call_at >= t0 and call_at < t1;
  select count(*) into from_calls from public.call_requests c join public.profiles p on p.id = c.profile_id
    where c.status = 'enrolled' and p.enrolled_at >= t0 and p.enrolled_at < t1;

  -- where buyers came from
  select string_agg(s || ' ' || n, ', ' order by n desc, s) into src_week from (
    select public.source_of(p) s, count(*) n from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.comp and p.enrolled_at >= t0 and p.enrolled_at < t1 group by 1) x;
  select string_agg(s || ' ' || n, ', ' order by n desc, s) into src_all from (
    select public.source_of(p) s, count(*) n from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.comp group by 1) x;

  -- ads
  select sum(amount) into spend_week from public.ad_spend where spent_on >= (t0 at time zone 'America/Chicago')::date and spent_on <= (t1 at time zone 'America/Chicago')::date;
  select sum(amount) into spend_all from public.ad_spend;
  select count(*) filter (where p.enrolled_at >= t0 and p.enrolled_at < t1), count(*) into ad_sales_week, ad_sales_all
    from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp and public.source_of(p) = 'Meta ads';
  select s.stage || ' (' || to_char(s.starts, 'Mon DD') || ' to ' || to_char(s.ends, 'Mon DD') || '): '
      || ops.money((select coalesce(sum(a.amount), 0) from public.ad_spend a where a.spent_on between s.starts and s.ends))
      || ' of ' || ops.money(s.budget)
    into stage_line from public.ad_stages() s
    where (now() at time zone 'America/Chicago')::date <= s.ends order by s.starts limit 1;

  -- the farmers' work
  select count(*) into signups from public.profiles where role = 'farmer' and created_at >= t0 and created_at < t1;
  select count(*) into contractors_new from public.contractors where created_at >= t0 and created_at < t1;
  select count(*) into leads_sent from public.leads where direction = 'outbound' and created_at >= t0 and created_at < t1;
  select count(*) into leads_closed from public.leads where status = 'closed' and closed_at >= t0 and closed_at < t1;
  select sum(fee_amount) into fees from public.leads where fee_paid and fee_paid_at >= t0 and fee_paid_at < t1;
  select string_agg(ops.who(farmer_id), ', ') into first_fees from (
    select farmer_id from public.leads where fee_paid and fee_paid_at is not null group by farmer_id
    having min(fee_paid_at) >= t0 and min(fee_paid_at) < t1) x;
  select count(*) into levelups from public.level_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select count(*), string_agg(nm, ', ' order by nm) into inactive_n, inactive from (
    select coalesce(nullif(btrim(p.full_name), ''), p.email) nm from public.profiles p
    where p.role = 'farmer' and p.enrollment_paid and not p.comp and p.enrolled_at < now() - interval '7 days'
      and p.enrolled_at > now() - interval '97 days'
      and coalesce(public.last_active(p.id), p.enrolled_at) < now() - interval '7 days') x;

  select count(*) into w_levels from public.level_requests where status = 'pending';
  select count(*) into w_questions from public.teacher_questions where answer is null;
  select count(*) into w_niches from public.profiles where niche_submitted_at is not null and niche_approved_at is null and niche_note is null;
  select count(*) into w_refunds from public.refund_requests where status = 'pending';

  return '📊 Monday report: ' || to_char(t0 at time zone 'America/Chicago', 'Mon DD') || ' to '
    || to_char(t1 at time zone 'America/Chicago', 'Mon DD') || E'\n\n'
    || E'💰 Money (this week)\n'
    || 'New paid farmers: ' || paid_n || coalesce(' (' || new_names || ')', '') || E'\n'
    || 'Real revenue: ' || ops.money(rev) || E' (before Stripe fees, free accounts left out)\n'
    || 'Bonuses paid out: ' || ops.money(comm) || ', still owed: ' || ops.money(owed) || E'\n'
    || 'Refunds approved: ' || refunds || E'\n\n'
    || E'🎯 $30k goal\n'
    || ops.money(rev_all) || ' of ' || ops.money(goal) || ' (' || round(100 * coalesce(rev_all, 0) / goal) || '%) from ' || farmers_all || ' paying farmers'
    || case when comps > 0 then ' (+' || comps || ' free)' else '' end || E'\n'
    || 'About ' || ceil(greatest(0, goal - coalesce(rev_all, 0)) / 499) || ' more farmers at $499 by Dec 31, ' || days_left || E' days left\n\n'
    || E'📞 Calls with you\n'
    || 'Forms filled: ' || requests || ', calls booked: ' || booked || E'\n'
    || 'Calls held: ' || held || ', showed: ' || showed || ', no-shows: ' || no_show
    || case when showed + no_show > 0 then ', show rate ' || round(100.0 * showed / (showed + no_show)) || '%' else '' end || E'\n'
    || 'Enrolled after a call: ' || from_calls || E'\n\n'
    || E'🧭 Where buyers came from\n'
    || 'This week: ' || coalesce(src_week, 'nobody new') || E'\n'
    || 'All time: ' || coalesce(src_all, 'nobody yet') || E'\n\n'
    || E'📣 Ads\n'
    || 'Spend this week: ' || ops.money(spend_week) || ', total: ' || ops.money(spend_all) || E' of $3,750\n'
    || coalesce(stage_line || E'\n', '')
    || 'Sales from ads: ' || ad_sales_week || ' this week, ' || ad_sales_all || E' total\n'
    || 'Cost per sale from ads: ' || case when ad_sales_all > 0 then ops.money(coalesce(spend_all, 0) / ad_sales_all) else 'no ad sales yet' end || E'\n\n'
    || E'🌱 Farmers (this week)\n'
    || 'New signups: ' || signups || ', contractors added: ' || contractors_new || E'\n'
    || 'Leads sent: ' || leads_sent || ', closed: ' || leads_closed || ', fees collected: ' || ops.money(fees) || E'\n'
    || 'First fees: ' || coalesce(first_fees, 'none') || E'\n'
    || 'Level-ups approved: ' || levelups || E'\n'
    || 'Inactive 7+ days: ' || inactive_n || coalesce(' (' || inactive || ')', '') || E'\n\n'
    || E'⏳ Waiting on you\n'
    || 'Level-up requests: ' || w_levels || ', questions: ' || w_questions
    || ', niches: ' || w_niches || ', refunds: ' || w_refunds || E'\n'
    || 'https://leadfarminghq.com/app/';
end;
$$;
revoke execute on all functions in schema ops from public, anon, authenticated;
