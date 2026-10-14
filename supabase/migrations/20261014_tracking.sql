-- Tracking (Alex, 2026-10-14): how each farmer heard about us (asked at sign-up) and the ad tags
-- (utm_*, fbclid, ?ref) from their first visit, stored on the profile for the Monday report's source breakdown.
alter table public.profiles add column if not exists heard_about text check (length(heard_about) <= 80);
alter table public.profiles add column if not exists attribution jsonb not null default '{}';

-- same as before, plus heard_about and the first-visit tags from the sign-up form
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare rec uuid; m jsonb := new.raw_user_meta_data;
begin
  select id into rec from public.profiles
   where lower(email) = lower(nullif(trim(m->>'recruiter_email'), ''));
  insert into public.profiles (id, email, full_name, phone, recruited_by, heard_about, attribution)
  values (new.id, new.email, m->>'full_name', m->>'phone', rec, left(nullif(btrim(m->>'heard_about'), ''), 80),
    coalesce((select jsonb_object_agg(k, left(v, 200)) from jsonb_each_text(case when jsonb_typeof(m->'attribution') = 'object' then m->'attribution' else '{}' end) x(k, v)
      where k in ('utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'fbclid', 'ref', 'landing', 'referrer', 'first_seen')), '{}'));
  if rec is not null then
    insert into public.recruiter_payouts (recruiter_id, recruit_id) values (rec, new.id);
  end if;
  return new;
end $$;

-- Where a farmer came from, in one word, for reports: an ad, a referral, a call with Alex, or what they told us
create or replace function public.source_of(p public.profiles) returns text
language sql stable security definer set search_path = public as $$
  select case
    when lower(coalesce(p.attribution->>'utm_source', '')) in ('facebook', 'fb', 'instagram', 'ig', 'meta') or p.attribution ? 'fbclid'
      or p.heard_about = 'Facebook or Instagram ad' then 'Meta ads'
    when p.recruited_by is not null or p.heard_about = 'A friend or family member' then 'Referral'
    when exists (select 1 from public.call_requests c where c.profile_id = p.id) or p.heard_about = 'Talked with Alex' then 'Call with Alex'
    when nullif(p.attribution->>'utm_source', '') is not null then initcap(p.attribution->>'utm_source')
    else coalesce(nullif(p.heard_about, ''), 'Unknown') end;
$$;
revoke execute on function public.source_of(public.profiles) from public, anon, authenticated;
