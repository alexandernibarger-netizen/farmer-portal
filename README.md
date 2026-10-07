# Farmer Portal

Members-only CRM for the Lead Farming Mentoring Program. Farmers track contractors through the 9-stage program and log leads and referral fees; admins track enrollments and recruiter payouts.

- `index.html`: the public landing page at leadfarminghq.com (static). It forwards signed-in visitors and email links (confirm, password reset) to the portal.
- `app/index.html`: the portal itself (static, no build step), at leadfarminghq.com/app/. `?signup` opens Create account; `?ref=email` fills in the recruiter.
- `config.js`: Supabase project URL and publishable key (safe to be public; row-level security protects the data)
- `supabase/schema.sql`: database schema reference
