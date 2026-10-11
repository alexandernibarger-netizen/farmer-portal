-- Telegram alerts for Alex: dashboard events that need attention, plus a weekly stats summary.
-- The bot token and chat id live in Supabase Vault (names telegram_bot_token, telegram_chat_id),
-- added by hand, never in this file. With either missing, nothing is sent.
create extension if not exists pg_cron;
create schema if not exists ops;
revoke all on schema ops from public, anon, authenticated;

create or replace function ops.telegram(msg text) returns void
language plpgsql security definer set search_path = ops, public as $$
declare tok text; chat text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into chat from vault.decrypted_secrets where name = 'telegram_chat_id';
  if tok is null or chat is null or msg is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', left(msg, 4000), 'disable_web_page_preview', true));
end;
$$;

create or replace function ops.who(f uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(full_name), ''), email, 'A farmer') from public.profiles where id = f;
$$;

create or replace function ops.money(n numeric) returns text
language sql immutable as $$ select to_char(coalesce(n, 0), 'FM$999,999,990.00') $$;

-- One trigger function for every table we watch; each branch builds the alert text.
-- Alerts are best effort: a failure here must never block the farmer's action.
create or replace function ops.on_dashboard_event() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare msg text; lvl text;
begin
  begin
    if tg_table_name = 'profiles' then
      if tg_op = 'INSERT' and new.role = 'farmer' then
        msg := '👤 New signup: ' || coalesce(nullif(btrim(new.full_name), ''), new.email)
          || coalesce(' · ' || new.email, '') || E'\nThey still need to pay to unlock the portal.';
      elsif tg_op = 'UPDATE' then
        if new.niche_submitted_at is distinct from old.niche_submitted_at and new.niche_submitted_at is not null then
          msg := '🌱 Niche to review: ' || ops.who(new.id) || E'\n' || left(coalesce(new.niche, ''), 500);
        elsif new.terms_declined_at is distinct from old.terms_declined_at and new.terms_declined_at is not null then
          msg := '⚠️ ' || ops.who(new.id) || ' declined the enrollment terms.';
        end if;
      end if;
    elsif tg_table_name = 'level_requests' and tg_op = 'INSERT' then
      select name into lvl from public.levels where level = new.to_level;
      msg := '⬆️ Level-up request: ' || ops.who(new.farmer_id) || ' wants Level ' || new.to_level
        || coalesce(' (' || lvl || ')', '')
        || coalesce(E'\n"' || left(nullif(btrim(new.note), ''), 400) || '"', '')
        || coalesce(E'\n📎 ' || nullif(cardinality(new.files), 0) || ' proof file(s)', '');
    elsif tg_table_name = 'teacher_questions' and tg_op = 'INSERT' then
      select name into lvl from public.quizzes where key = new.quiz;
      msg := '❓ Question from ' || ops.who(new.farmer_id) || coalesce(' about the ' || lvl || ' quiz', '')
        || E':\n"' || left(new.body, 500) || '"';
    elsif tg_table_name = 'refund_requests' and tg_op = 'INSERT' then
      msg := '🔁 Refund package submitted by ' || ops.who(new.farmer_id) || '. Review it in Approvals.';
    elsif tg_table_name = 'recruiter_payouts' and tg_op = 'UPDATE'
          and new.status = 'owed' and old.status is distinct from 'owed' then
      msg := '💸 You owe ' || ops.money(new.amount) || ' to ' || ops.who(new.recruiter_id)
        || ' for recruiting ' || ops.who(new.recruit_id) || '.';
    end if;
    if msg is not null then
      perform ops.telegram(msg || E'\nhttps://leadfarminghq.com');
    end if;
  exception when others then
    raise warning 'telegram alert failed: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists telegram_alert on public.profiles;
create trigger telegram_alert after insert or update of niche_submitted_at, terms_declined_at on public.profiles
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.level_requests;
create trigger telegram_alert after insert on public.level_requests
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.teacher_questions;
create trigger telegram_alert after insert on public.teacher_questions
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.refund_requests;
create trigger telegram_alert after insert on public.refund_requests
  for each row execute function ops.on_dashboard_event();
drop trigger if exists telegram_alert on public.recruiter_payouts;
create trigger telegram_alert after update of status on public.recruiter_payouts
  for each row execute function ops.on_dashboard_event();

-- Weekly summary of the 7 days before it runs, plus all-time totals and what is waiting on Alex.
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
    where enrollment_paid and enrolled_at >= t0 and enrolled_at < t1;
  select sum(amount) into comm from public.recruiter_payouts where status = 'paid' and paid_at >= t0 and paid_at < t1;
  select sum(amount) into owed from public.recruiter_payouts where status = 'owed';
  select count(*) into refunds from public.refund_requests where status = 'approved' and reviewed_at >= t0 and reviewed_at < t1;
  select sum(enrollment_fee), count(*) into rev_all, farmers_all from public.profiles where enrollment_paid and role = 'farmer';
  select sum(amount) into comm_all from public.recruiter_payouts where status = 'paid';
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

revoke execute on all functions in schema ops from public, anon, authenticated;

-- Mondays 13:00 UTC = 8am Central (7am in winter)
select cron.unschedule('telegram-weekly-report') where exists (select 1 from cron.job where jobname = 'telegram-weekly-report');
select cron.schedule('telegram-weekly-report', '0 13 * * 1', $$select ops.telegram(ops.weekly_report())$$);
