-- Activation nudges (Alex, 2026-10-14): find paid farmers who are stuck, alert them in the portal and by email,
-- let Alex hand each one to a teacher, and send every farmer a weekly progress email.
-- Emails go through Resend's API with the key in Supabase Vault (name resend_api_key, added by hand).
-- Without the key, the in-portal alerts still go out and no email is sent.
-- Resend's free plan allows 100 emails a day, shared with sign-up and password emails, so these use at most
-- ops.email_cap() a day (60) and the rest is left for those.

-- the teacher (Alex or a verifier) checking in on a farmer
alter table public.profiles add column if not exists teacher_id uuid references public.profiles(id) on delete set null;

-- every nudge sent, so the same one isn't repeated and the daily email cap can be counted
create table if not exists public.nudges (
  id bigint generated always as identity primary key,
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('no_contractors', 'inactive', 'behind', 'weekly')),
  detail text,
  emailed boolean not null default false,
  created_at timestamptz not null default now());
create index if not exists nudges_farmer_kind on public.nudges (farmer_id, kind, created_at desc);
alter table public.nudges enable row level security;
create policy "nudges admin read" on public.nudges for select using (public.is_admin());

-- the last time a farmer logged anything (same sources as the dashboard's "last active")
create or replace function public.last_active(f uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(t) from (
    select max(created_at) t from public.contractors where farmer_id = f
    union all select max(created_at) from public.leads where farmer_id = f
    union all select max(created_at) from public.activities where farmer_id = f
    union all select max(created_at) from public.upsells where farmer_id = f
    union all select max(h.changed_at) from public.contractor_stage_history h join public.contractors c on c.id = h.contractor_id where c.farmer_id = f) x;
$$;
revoke execute on function public.last_active(uuid) from public, anon, authenticated;

-- Why a paid farmer is stuck: no contractors 48 hours after paying, nothing logged for 3 days,
-- or a 90-day quota whose date has passed. Free (comp) accounts and finished programs are left out.
create or replace function public.stuck_reasons(f uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles; pr jsonb; r jsonb := '[]'; la timestamptz; s jsonb;
begin
  select * into p from public.profiles where id = f;
  if p.id is null or p.role <> 'farmer' or not p.enrollment_paid or p.comp or p.enrolled_at is null
     or p.enrolled_at < now() - interval '90 days' then return r; end if;
  if p.enrolled_at < now() - interval '48 hours' and not exists (select 1 from public.contractors where farmer_id = f) then
    r := r || jsonb_build_object('kind', 'no_contractors', 'key', 'no_contractors', 'text', 'No contractors added since paying');
  end if;
  la := coalesce(public.last_active(f), p.enrolled_at);
  if la < now() - interval '3 days' then
    r := r || jsonb_build_object('kind', 'inactive', 'key', 'inactive', 'text', 'Nothing logged for ' || floor(extract(epoch from now() - la) / 86400)::int || ' days');
  end if;
  pr := public.refund_progress(f);
  for s in select * from jsonb_array_elements(coalesce(pr->'steps', '[]')) loop
    if not (s->>'met')::boolean and (s->>'deadline')::int < (pr->>'day')::int then
      r := r || jsonb_build_object('kind', 'behind', 'key', 'behind:' || (s->>'n'), 'step', (s->>'n')::int,
        'text', 'Behind on step ' || (s->>'n') || ', ' || (s->>'name') || ' (due day ' || (s->>'deadline') || ', at ' || (s->>'progress') || ')');
    end if;
  end loop;
  return r;
end $$;
revoke execute on function public.stuck_reasons(uuid) from public, anon, authenticated;

-- Admin Home: the stuck list, plus who can be assigned as a teacher (Alex and the verifiers)
create or replace function public.stuck_farmers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'farmers', coalesce((select jsonb_agg(x order by x->>'full_name') from (
      select jsonb_build_object('id', p.id, 'full_name', coalesce(nullif(btrim(p.full_name), ''), p.email), 'email', p.email, 'phone', p.phone,
        'day', floor(extract(epoch from now() - p.enrolled_at) / 86400)::int, 'reasons', public.stuck_reasons(p.id),
        'last_active', public.last_active(p.id), 'teacher_id', p.teacher_id,
        'last_nudge', (select max(n.created_at) from public.nudges n where n.farmer_id = p.id and n.kind <> 'weekly')) x
      from public.profiles p where p.role = 'farmer' and p.enrollment_paid and not p.comp) y
      where jsonb_array_length(x->'reasons') > 0), '[]'),
    'teachers', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'full_name', coalesce(nullif(btrim(t.full_name), ''), t.email)) order by t.role <> 'admin', t.full_name)
      from public.profiles t where t.role = 'admin' or t.verifier), '[]'));
end $$;
revoke execute on function public.stuck_farmers() from public, anon;
grant execute on function public.stuck_farmers() to authenticated;

-- Hand a farmer to a teacher; the teacher (if it isn't Alex) gets an alert in the portal
create or replace function public.assign_teacher(farmer uuid, teacher uuid) returns void
language plpgsql security definer set search_path = public as $$
declare why text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if teacher is not null and not exists (select 1 from public.profiles where id = teacher and (role = 'admin' or verifier)) then
    raise exception 'Only Alex or a verifier can be a teacher';
  end if;
  update public.profiles set teacher_id = teacher where id = farmer;
  if teacher is not null and teacher is distinct from auth.uid() then
    select string_agg(r->>'text', '; ') into why from jsonb_array_elements(public.stuck_reasons(farmer)) r;
    insert into public.notifications (farmer_id, body) select teacher,
      'Alex asked you to check in with ' || coalesce(nullif(btrim(full_name), ''), email) || coalesce(' (' || phone || ')', '')
      || coalesce('. ' || why || '.', '.') || ' They are under "Farmers to check in on" on your Home.'
      from public.profiles where id = farmer;
  end if;
end $$;
revoke execute on function public.assign_teacher(uuid, uuid) from public, anon;
grant execute on function public.assign_teacher(uuid, uuid) to authenticated;

-- A teacher's own list of farmers to check in on
create or replace function public.my_students() returns table (full_name text, email text, phone text, day int, reasons jsonb, last_active timestamptz)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(p.full_name), ''), p.email), p.email, p.phone,
    floor(extract(epoch from now() - p.enrolled_at) / 86400)::int, public.stuck_reasons(p.id), public.last_active(p.id)
  from public.profiles p where p.teacher_id = auth.uid() and p.enrollment_paid and public.is_verifier()
  order by p.full_name;
$$;
revoke execute on function public.my_students() from public, anon;
grant execute on function public.my_students() to authenticated;

-- ---------- email ----------
create or replace function ops.email_cap() returns int language sql immutable as 'select 60';
create or replace function ops.emails_today() returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.nudges where emailed and created_at >= date_trunc('day', now());
$$;

-- Sends one email through Resend. Returns false (and sends nothing) without the Vault key.
create or replace function ops.send_email(to_addr text, subject text, html text) returns boolean
language plpgsql security definer set search_path = ops, public as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key';
  if k is null or coalesce(to_addr, '') = '' then return false; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object('from', 'Lead Farming HQ <noreply@leadfarminghq.com>', 'to', jsonb_build_array(to_addr),
      'reply_to', 'support@leadfarminghq.com', 'subject', subject, 'html', html));
  return true;
end $$;

-- the same layout for every email: greeting, body paragraphs, one button to the portal
create or replace function ops.email_html(first text, paras text[]) returns text
language sql immutable as $$
  select '<div style="font-family:Arial,sans-serif;font-size:16px;line-height:1.5;color:#2B3A2E;max-width:560px">'
    || '<p>Hi ' || coalesce(nullif(replace(replace(replace(first, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), ''), 'there') || ',</p>'
    || (select string_agg('<p>' || x || '</p>', '') from unnest(paras) x)
    || '<p><a href="https://leadfarminghq.com/app/" style="display:inline-block;background:#58CC02;color:#fff;font-weight:bold;text-decoration:none;padding:12px 20px;border-radius:10px">Open the portal</a></p>'
    || '<p>Alex<br>Lead Farming</p>'
    || '<p style="font-size:12px;color:#777">You get these emails because you are enrolled in the Lead Farming Mentoring Program. Questions? Reply to this email or write to support@leadfarminghq.com.</p></div>';
$$;

-- at most one email per farmer per day
create or replace function ops.emailed_today(f uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.nudges where farmer_id = f and emailed and created_at >= date_trunc('day', now()));
$$;

create or replace function ops.first_name(f uuid) returns text language sql stable security definer set search_path = public as $$
  select split_part(btrim(coalesce(full_name, '')), ' ', 1) from public.profiles where id = f;
$$;

-- ---------- the daily run ----------
-- Each stuck reason is nudged once (no contractors; each missed quota), or every 3 days (nothing logged).
-- A farmer gets at most one email a day (the most urgent reason); the other reasons still show in the portal.
-- Then weekly progress emails go to farmers who haven't had one in 7 days. Emails stop at the daily cap;
-- the in-portal alerts always go out. Returns how many alerts and emails went out.
create or replace function ops.run_nudges() returns text
language plpgsql security definer set search_path = ops, public as $$
declare
  p record; r jsonb; body text; subj text; paras text[]; sent boolean; n_alerts int := 0; n_emails int := 0;
  pr jsonb; nxt jsonb; c_week int; c_all int; calls_week int; comm_week int; met int; total int;
begin
  for p in select pp.id, pp.email from public.profiles pp
           where pp.role = 'farmer' and pp.enrollment_paid and not pp.comp and pp.enrolled_at is not null
           order by pp.enrolled_at loop
    for r in select * from jsonb_array_elements(public.stuck_reasons(p.id))
             order by case r->>'kind' when 'no_contractors' then 0 when 'behind' then 1 else 2 end loop
      continue when exists (select 1 from public.nudges n where n.farmer_id = p.id and n.kind = r->>'kind' and n.detail = r->>'key'
        and (r->>'kind' <> 'inactive' or n.created_at > now() - interval '3 days'));
      if r->>'kind' = 'no_contractors' then
        body := 'You haven''t added a contractor yet. Open Pipeline, press Add, and log the first one you find today. The Level 1 lessons show you where to look.';
        subj := 'Your first contractor';
      elsif r->>'kind' = 'inactive' then
        body := 'We haven''t seen anything logged in the portal for a few days. Log today''s calls or comments, even a few, to keep your 5-days-a-week streak going. Stuck on something? Ask a teacher from the Learn page.';
        subj := 'Pick up where you left off';
      else
        body := r->>'text' || '. The 90 days page shows what''s left. Catch up as soon as you can, and ask a teacher from the Learn page if you''re stuck.';
        subj := 'A 90-day goal date has passed';
      end if;
      insert into public.notifications (farmer_id, body) values (p.id, body);
      n_alerts := n_alerts + 1;
      sent := false;
      if ops.emails_today() < ops.email_cap() and not ops.emailed_today(p.id) then
        sent := ops.send_email(p.email, subj, ops.email_html(ops.first_name(p.id), array[body]));
      end if;
      if sent then n_emails := n_emails + 1; end if;
      insert into public.nudges (farmer_id, kind, detail, emailed) values (p.id, r->>'kind', r->>'key', sent);
    end loop;
  end loop;

  -- weekly progress email, during the 90 days (plus the week to send the refund package)
  for p in select pp.id, pp.email, pp.enrolled_at from public.profiles pp
           where pp.role = 'farmer' and pp.enrollment_paid and not pp.comp and pp.enrolled_at is not null
             and pp.enrolled_at < now() - interval '6 days' and pp.enrolled_at > now() - interval '97 days'
             and not exists (select 1 from public.nudges n where n.farmer_id = pp.id and n.kind = 'weekly' and n.created_at > now() - interval '6 days 20 hours')
             and not ops.emailed_today(pp.id)
           order by pp.enrolled_at loop
    exit when ops.emails_today() >= ops.email_cap();
    pr := public.refund_progress(p.id);
    select count(*) filter (where created_at > now() - interval '7 days'), count(*) into c_week, c_all from public.contractors where farmer_id = p.id;
    select count(*) filter (where kind = 'call'), coalesce(sum(count) filter (where kind = 'comments'), 0) into calls_week, comm_week
      from public.activities where farmer_id = p.id and created_at > now() - interval '7 days';
    select count(*) filter (where (s->>'met')::boolean), count(*) into met, total from jsonb_array_elements(pr->'steps') s;
    select s into nxt from jsonb_array_elements(pr->'steps') s where not (s->>'met')::boolean and (s->>'deadline')::int >= (pr->>'day')::int
      order by (s->>'deadline')::int limit 1;
    paras := array[
      'Here''s your week. You''re on day ' || least((pr->>'day')::int, 90) || ' of 90.',
      'This week: ' || c_week || ' contractors added (' || c_all || ' in total), ' || calls_week || ' calls logged, ' || comm_week || ' neighbor comments logged.',
      met || ' of ' || total || ' program steps met.'
        || coalesce(' Next up: step ' || (nxt->>'n') || ', ' || (nxt->>'name') || ', ' || (nxt->>'quota') || ', by day ' || (nxt->>'deadline') || '. You''re at ' || (nxt->>'progress') || '.', '')];
    sent := ops.send_email(p.email, 'Your week in Lead Farming: day ' || least((pr->>'day')::int, 90) || ' of 90', ops.email_html(ops.first_name(p.id), paras));
    exit when not sent;  -- no Resend key yet
    insert into public.nudges (farmer_id, kind, detail, emailed) values (p.id, 'weekly', 'day ' || (pr->>'day'), true);
    n_emails := n_emails + 1;
  end loop;
  return n_alerts || ' alerts, ' || n_emails || ' emails';
end $$;

revoke execute on all functions in schema ops from public, anon, authenticated;

-- every day at 15:00 UTC (10am Central, 9am in winter)
select cron.unschedule('activation-nudges') where exists (select 1 from cron.job where jobname = 'activation-nudges');
select cron.schedule('activation-nudges', '0 15 * * *', $$select ops.run_nudges()$$);
