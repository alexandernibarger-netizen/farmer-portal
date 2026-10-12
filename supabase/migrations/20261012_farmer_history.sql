-- Farmer profiles for Alex: everything that ever happened to one farmer, oldest to newest.
-- Some of it only lives on the profile row (the niche list, terms, level, verifier), where each change
-- overwrote the last one. farmer_events keeps every change from now on; older ones are backfilled
-- from what the profile still shows.

create table public.farmer_events (
  id bigint generated always as identity primary key,
  farmer_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,          -- signed_up, paid, unpaid, terms_accepted, terms_declined, niche_submitted,
                               -- niche_approved, niche_sent_back, level_changed, verifier_on, verifier_off
  detail jsonb not null default '{}',
  actor_id uuid,               -- who made the change (null = the farmer themselves, Stripe, or unknown)
  created_at timestamptz not null default now()
);
create index farmer_events_farmer on public.farmer_events (farmer_id, created_at);
alter table public.farmer_events enable row level security;
create policy "admin reads events" on public.farmer_events for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.farmer_events from authenticated, anon;

create or replace function public.log_profile_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare who uuid := case when auth.uid() is distinct from new.id then auth.uid() end;
begin
  if tg_op = 'INSERT' then
    insert into public.farmer_events (farmer_id, kind, created_at) values (new.id, 'signed_up', new.created_at);
    return new;
  end if;
  if new.enrollment_paid and not old.enrollment_paid then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id) values (new.id, 'paid', jsonb_build_object('amount', new.enrollment_fee), who);
  elsif old.enrollment_paid and not new.enrollment_paid then
    insert into public.farmer_events (farmer_id, kind, actor_id) values (new.id, 'unpaid', who);
  end if;
  if new.terms_accepted_at is distinct from old.terms_accepted_at and new.terms_accepted_at is not null then
    insert into public.farmer_events (farmer_id, kind, detail) values (new.id, 'terms_accepted', jsonb_build_object('version', new.terms_version));
  end if;
  if new.terms_declined_at is distinct from old.terms_declined_at and new.terms_declined_at is not null then
    insert into public.farmer_events (farmer_id, kind) values (new.id, 'terms_declined');
  end if;
  if new.niche_submitted_at is distinct from old.niche_submitted_at and new.niche_submitted_at is not null then
    insert into public.farmer_events (farmer_id, kind, detail) values (new.id, 'niche_submitted', jsonb_build_object('list', new.niche));
  end if;
  if new.niche_approved_at is distinct from old.niche_approved_at and new.niche_approved_at is not null then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id) values (new.id, 'niche_approved', jsonb_build_object('list', new.niche), who);
  end if;
  if new.niche_note is distinct from old.niche_note and new.niche_note is not null then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id)
      values (new.id, 'niche_sent_back', jsonb_build_object('note', new.niche_note, 'list', new.niche), who);
  end if;
  if new.level is distinct from old.level then
    insert into public.farmer_events (farmer_id, kind, detail, actor_id)
      values (new.id, 'level_changed', jsonb_build_object('from', old.level, 'to', new.level), who);
  end if;
  if new.verifier is distinct from old.verifier then
    insert into public.farmer_events (farmer_id, kind, actor_id) values (new.id, case when new.verifier then 'verifier_on' else 'verifier_off' end, who);
  end if;
  return new;
exception when others then
  return new;  -- the history is a record, never a reason to block the change itself
end $$;
revoke execute on function public.log_profile_events() from public, anon, authenticated;

create trigger profiles_history after insert or update on public.profiles
  for each row execute function public.log_profile_events();

-- Backfill from what the profiles show today (times the profile never kept are marked as such)
insert into public.farmer_events (farmer_id, kind, detail, created_at)
select id, 'signed_up', '{}', created_at from public.profiles
union all
select id, 'paid', jsonb_build_object('amount', enrollment_fee), enrolled_at from public.profiles where enrollment_paid and enrolled_at is not null
union all
select id, 'terms_accepted', jsonb_build_object('version', terms_version), terms_accepted_at from public.profiles where terms_accepted_at is not null
union all
select id, 'terms_declined', '{}', terms_declined_at from public.profiles where terms_declined_at is not null
union all
select id, 'niche_submitted', jsonb_build_object('list', niche), niche_submitted_at from public.profiles where niche_submitted_at is not null
union all
select id, 'niche_approved', jsonb_build_object('list', niche), niche_approved_at from public.profiles where niche_approved_at is not null
union all
select id, 'niche_sent_back', jsonb_build_object('note', niche_note, 'list', niche, 'time_unknown', true), niche_submitted_at
  from public.profiles where niche_note is not null and niche_submitted_at is not null;

-- One farmer's whole history, for their profile page. Admin only.
create or replace function public.farmer_history(p_farmer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare nm jsonb;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select coalesce(jsonb_object_agg(id, coalesce(nullif(btrim(full_name), ''), email)), '{}') into nm from public.profiles where role = 'admin' or verifier
    or id in (select recruit_id from public.recruiter_payouts where recruiter_id = p_farmer)
    or id = (select recruited_by from public.profiles where id = p_farmer);
  return jsonb_build_object(
    'names', nm,
    'profile', (select jsonb_build_object('niche', niche, 'niche_submitted_at', niche_submitted_at, 'niche_approved_at', niche_approved_at,
        'niche_note', niche_note, 'recruited_by', recruited_by, 'phone', phone, 'created_at', created_at) from public.profiles where id = p_farmer),
    'events', coalesce((select jsonb_agg(e order by e.at, e.ord, e.seq) from (
      select created_at at, 0 ord, id seq, kind, detail, actor_id actor from public.farmer_events where farmer_id = p_farmer
      union all
      select r.created_at, 1, 0, 'level_requested', jsonb_build_object('to', r.to_level, 'note', r.note, 'files', cardinality(r.files)), null
        from public.level_requests r where r.farmer_id = p_farmer
      union all
      select r.reviewed_at, 2, 0, 'level_' || r.status, jsonb_build_object('to', r.to_level, 'note', r.review_note), r.reviewer_id
        from public.level_requests r where r.farmer_id = p_farmer and r.reviewed_at is not null
      union all
      select t.created_at, 1, 0, 'question_asked', jsonb_build_object('quiz', q.name, 'body', t.body), null
        from public.teacher_questions t left join public.quizzes q on q.key = t.quiz where t.farmer_id = p_farmer
      union all
      select t.answered_at, 2, 0, 'question_answered', jsonb_build_object('quiz', q.name, 'body', t.body, 'answer', t.answer), t.answered_by
        from public.teacher_questions t left join public.quizzes q on q.key = t.quiz where t.farmer_id = p_farmer and t.answered_at is not null
      union all
      select a.created_at, 1, 0, 'quiz_taken', jsonb_build_object('quiz', q.name, 'score', a.score, 'total', a.total), null
        from public.quiz_attempts a left join public.quizzes q on q.key = a.quiz where a.farmer_id = p_farmer
      union all
      select r.created_at, 1, 0, 'refund_submitted', jsonb_build_object('note', r.note, 'files', cardinality(r.files)), null
        from public.refund_requests r where r.farmer_id = p_farmer
      union all
      select r.reviewed_at, 2, 0, 'refund_' || r.status, jsonb_build_object('note', r.review_note), r.reviewer_id
        from public.refund_requests r where r.farmer_id = p_farmer and r.reviewed_at is not null
      union all
      select p.created_at, 1, 0, 'referral_signed_up', jsonb_build_object('recruit', p.recruit_id, 'amount', p.amount, 'status', p.status), null
        from public.recruiter_payouts p where p.recruiter_id = p_farmer
      union all
      select p.paid_at, 2, 0, 'referral_paid_out', jsonb_build_object('recruit', p.recruit_id, 'amount', p.amount), null
        from public.recruiter_payouts p where p.recruiter_id = p_farmer and p.paid_at is not null
      union all
      select p.clawback_at, 3, 0, 'referral_clawback', jsonb_build_object('recruit', p.recruit_id, 'amount', p.amount, 'settled', p.clawback_settled_at is not null), null
        from public.recruiter_payouts p where p.recruiter_id = p_farmer and p.clawback_at is not null
      union all
      select l.created_at, 1, 0, 'lead_' || l.direction, jsonb_build_object('business', c.business_name, 'customer', l.customer_name, 'job', l.job_description), null
        from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = p_farmer
      union all
      select l.closed_at, 2, 0, 'lead_closed', jsonb_build_object('business', c.business_name, 'customer', l.customer_name, 'fee', l.fee_amount, 'direction', l.direction), null
        from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = p_farmer and l.closed_at is not null
      union all
      select l.fee_paid_at, 3, 0, 'fee_paid', jsonb_build_object('business', c.business_name, 'fee', l.fee_amount), null
        from public.leads l left join public.contractors c on c.id = l.contractor_id where l.farmer_id = p_farmer and l.fee_paid_at is not null
      union all
      select u.closed_at, 2, 0, 'upsell_closed', jsonb_build_object('business', c.business_name, 'product', u.product, 'amount', u.amount), null
        from public.upsells u left join public.contractors c on c.id = u.contractor_id where u.farmer_id = p_farmer and u.closed_at is not null
      union all  -- contractors and calls are many, so one line per day
      select min(created_at), 1, 0, 'contractors_added', jsonb_build_object('count', count(*)), null
        from public.contractors where farmer_id = p_farmer group by created_at::date
      union all
      select min(created_at), 1, 0, 'calls_logged', jsonb_build_object('count', count(*)), null
        from public.activities where farmer_id = p_farmer and kind = 'call' group by created_at::date
    ) e), '[]'));
end $$;
revoke execute on function public.farmer_history(uuid) from public, anon;
grant execute on function public.farmer_history(uuid) to authenticated;
