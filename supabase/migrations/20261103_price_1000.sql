-- Price change (Alex, 2026-11-03): enrollment is now $1,000.
-- profiles.enrollment_fee is each farmer's refund cap. The Stripe webhook records what they actually paid,
-- so farmers who already paid $499 or $500 keep that. Unpaid sign-ups move to the new price.
alter table public.profiles alter column enrollment_fee set default 1000;
update public.profiles set enrollment_fee = 1000 where not enrollment_paid and enrollment_fee in (499, 500);
