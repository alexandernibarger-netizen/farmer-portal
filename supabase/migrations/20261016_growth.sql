-- Growth tab (Alex, 2026-10-16): the owner's checklist for the $30k-by-Dec-31 plan. Benchmarks ("goals") are
-- what we want to hit, each with the steps we're taking to get there. A goal can track a live number from the
-- database (metric + target); the rest are ticked by hand. Owner (admin) only.
create table if not exists public.growth_items (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('goal', 'step')),
  goal_id bigint references public.growth_items(id) on delete cascade,  -- a step belongs to a goal
  title text not null check (length(btrim(title)) between 1 and 200),
  detail text check (length(detail) <= 1000),
  link text check (link ~ '^https://' and length(link) <= 500),
  who text check (length(who) <= 60),             -- who's doing the step: Alex, Claude, the teachers
  metric text check (metric ~ '^[a-z_]{1,40}$'),  -- a key from growth_numbers()
  target numeric,
  lower_is_better boolean not null default false, -- e.g. cost per sale
  due date,
  done_at timestamptz,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check ((kind = 'goal') = (goal_id is null)));
create index if not exists growth_items_goal on public.growth_items (goal_id);
alter table public.growth_items enable row level security;
create policy "growth admin" on public.growth_items for all using (public.is_admin()) with check (public.is_admin());

-- The live numbers the goals track. Free (comp) accounts are left out, same as the dashboard and Monday report.
create or replace function public.growth_numbers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; showed int; no_show int; spent numeric; ad_sales int;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select count(*) filter (where status in ('showed', 'enrolled') and call_at is not null), count(*) filter (where status = 'no_show')
    into showed, no_show from public.call_requests;
  select coalesce(sum(amount), 0) into spent from public.ad_spend;
  select count(*) into ad_sales from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp and public.source_of(p) = 'Meta ads';
  with payers as (select * from public.profiles where role = 'farmer' and enrollment_paid and not comp)
  select jsonb_build_object(
    'revenue', coalesce((select sum(enrollment_fee) from payers), 0),
    'payers', (select count(*) from payers),
    'new_paid_week', (select count(*) from payers where enrolled_at > now() - interval '7 days'),
    'new_paid_4wk', (select count(*) from payers where enrolled_at > now() - interval '28 days'),
    'calls_booked_week', (select count(*) from public.call_requests where booked_at > now() - interval '7 days'),
    'calls_booked', (select count(*) from public.call_requests where booked_at is not null),
    'show_rate', case when showed + no_show > 0 then round(100.0 * showed / (showed + no_show)) end,
    'ad_spend', spent,
    'ad_sales', ad_sales,
    'cost_per_sale', case when ad_sales > 0 then round(spent / ad_sales, 2) end,
    'referral_sales', (select count(*) from payers p where public.source_of(p) = 'Referral'),
    'activated_pct', (select case when count(*) > 0 then round(100.0 * count(*) filter (where exists (select 1 from public.contractors c where c.farmer_id = p.id)) / count(*)) end from payers p),
    'active_week_pct', (select case when count(*) > 0 then round(100.0 * count(*) filter (where public.last_active(p.id) > now() - interval '7 days') / count(*)) end from payers p),
    'leads_sent', (select count(*) from public.leads where direction = 'outbound'),
    'farmers_with_fee', (select count(distinct farmer_id) from public.leads where fee_paid),
    'level2', (select count(*) from payers where level >= 2)) into r;
  return r;
end $$;
revoke execute on function public.growth_numbers() from public, anon;
grant execute on function public.growth_numbers() to authenticated;

-- Starting checklist, from the growth plan Alex approved 2026-10-14. Only filled in once, on an empty table.
do $$
declare g bigint;
begin
  if exists (select 1 from public.growth_items) then return; end if;

  insert into public.growth_items (kind, title, detail, metric, target, due, sort_order) values
    ('goal', '$30,000 in enrollment revenue', 'The main goal. About 5 new paying farmers a week at $499 gets there.', 'revenue', 30000, '2026-12-31', 10)
    returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, done_at, sort_order) values
    ('step', g, 'Free accounts (zim, Julian) left out of revenue; Drew marked paid', 'Alex', now(), 1),
    ('step', g, 'Monday report on Telegram tracks the goal, calls and ads', 'Claude', now(), 2);

  insert into public.growth_items (kind, title, detail, metric, target, due, sort_order) values
    ('goal', 'Checkpoint: $10,000', 'Halfway-to-pace check before ads ramp up.', 'revenue', 10000, '2026-11-15', 20),
    ('goal', 'Checkpoint: $20,000', 'Where we need to be going into the biggest ad stage.', 'revenue', 20000, '2026-12-01', 30);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', '5 new paying farmers a week', 'Last 7 days. The pace the $30k goal needs.', 'new_paid_week', 5, 40) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, '"Book a call with Alex" on the landing page', 'Claude', 'https://leadfarminghq.com/', now(), 1),
    ('step', g, '"Share your link" card on every farmer''s Home', 'Claude', null, now(), 2),
    ('step', g, 'Send the founder video for the "Meet Alex" section', 'Alex', null, null, 3);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', '10 booked calls a week', 'Last 7 days. Assumes about half of calls enroll, so 10 calls makes 5 sales.', 'calls_booked_week', 10, 50) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, 'Cal.com calendar on the landing page', 'Claude', 'https://cal.com/zimbux/intro-call', now(), 1),
    ('step', g, 'Meta pixel tracking page views, bookings and payments', 'Claude', 'https://business.facebook.com/events_manager2', now(), 2),
    ('step', g, 'Add the Cal.com webhook so booked calls reach Telegram and Home', 'Alex', 'https://app.cal.com/settings/developer/webhooks', null, 3);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', 'Show rate of 70% or better', 'Of calls that have happened, how many people showed up.', 'show_rate', 70, 60) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, sort_order) values
    ('step', g, 'Mark Showed or No-show on each call under "Calls with you" on Home', 'Alex', 'https://leadfarminghq.com/app/', 1);

  insert into public.growth_items (kind, title, detail, metric, target, lower_is_better, due, sort_order) values
    ('goal', 'Ads: cost per sale under $250', '$3,750 budget in 3 stages. Ad copy: no income figures, no "guarantee", never mention the recruiting bonus.', 'cost_per_sale', 250, true, '2026-12-24', 70)
    returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, due, sort_order) values
    ('step', g, 'Stage 1: $500, Nov 1 to 14', 'Alex', 'https://adsmanager.facebook.com/', '2026-11-01', 1),
    ('step', g, 'Stage 2: $1,250, Nov 15 to 30', 'Alex', 'https://adsmanager.facebook.com/', '2026-11-15', 2),
    ('step', g, 'Stage 3: $2,000, Dec 1 to 24', 'Alex', 'https://adsmanager.facebook.com/', '2026-12-01', 3),
    ('step', g, 'Log ad spend each week in the Ads card on Home', 'Alex', 'https://leadfarminghq.com/app/', null, 4);

  insert into public.growth_items (kind, title, detail, metric, target, sort_order) values
    ('goal', 'Every paid farmer has contractors', 'Share of paying farmers with at least one contractor logged.', 'activated_pct', 100, 80) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, 'Daily nudges to stuck farmers (alerts and email)', 'Claude', null, now(), 1),
    ('step', g, 'Julian and Vincent set as teachers', 'Alex', null, now(), 2),
    ('step', g, 'Hand each stuck farmer to a teacher on Home', 'Alex', 'https://leadfarminghq.com/app/', null, 3);

  insert into public.growth_items (kind, title, detail, metric, target, due, sort_order) values
    ('goal', 'First farmer earns a referral fee', 'Real results are the proof every ad and call leans on.', 'farmers_with_fee', 1, '2026-11-15', 90) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, sort_order) values
    ('step', g, '30-day "first fee" push with the current farmers', 'Alex and teachers', 1),
    ('step', g, 'Ask the first earners for a case study (with permission)', 'Alex', 2);

  insert into public.growth_items (kind, title, detail, due, sort_order) values
    ('goal', 'Ready for ads', 'Compliance in place before the first ad dollar.', '2026-11-01', 100) returning id into g;
  insert into public.growth_items (kind, goal_id, title, who, link, done_at, sort_order) values
    ('step', g, 'Lesson 4b script discloses the referral fee', 'Claude', null, now(), 1),
    ('step', g, 'New Terms: bonuses never reduce new farmers'' refunds', 'Claude', 'https://leadfarminghq.com/terms/', now(), 2),
    ('step', g, 'Privacy Policy and cookie notice for the pixel', 'Claude', 'https://leadfarminghq.com/privacy/', now(), 3),
    ('step', g, 'File the LLC (Lead Farming HQ LLC)', 'Alex', 'https://www.sos.state.tx.us/corp/sosda/index.shtml', null, 4),
    ('step', g, 'Have a Texas business lawyer look over the Terms', 'Alex', null, null, 5);
end $$;
