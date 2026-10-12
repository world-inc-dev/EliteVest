-- EliteVest follow-up: seed catalog and create a profile + zero-balance wallet on signup.
-- Run after 202610120001_elitevest_foundation.sql.
-- This does NOT credit bonuses or enable payouts.

CREATE OR REPLACE FUNCTION public.ev_handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer uuid;
  v_code text;
BEGIN
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  IF NEW.raw_user_meta_data ? 'referral_code' THEN
    SELECT user_id INTO v_referrer
    FROM public.ev_profiles
    WHERE referral_code = NEW.raw_user_meta_data ->> 'referral_code'
    LIMIT 1;
  END IF;

  INSERT INTO public.ev_profiles(user_id, full_name, phone, referral_code, referred_by)
  VALUES (
    NEW.id,
    NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''),
    NULLIF(NEW.raw_user_meta_data ->> 'phone', ''),
    v_code,
    v_referrer
  )
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.ev_wallets(user_id, currency, available_balance, reserved_balance)
  VALUES (NEW.id, 'UGX', 0, 0)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ev_on_auth_user_created ON auth.users;
CREATE TRIGGER ev_on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.ev_handle_new_user();

INSERT INTO public.ev_packages
  (name, principal_amount, duration_days, daily_projection, is_active, terms)
VALUES
  ('Bronze',   20000,   30,   1000, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('Silver',   50000,   30,   2500, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('Gold',    100000,   30,   5000, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('Platinum',200000,   30,  10000, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('Diamond', 500000,   30,  25000, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('VIP',    1000000,   30,  50000, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('Mega',   2000000,   30, 100000, TRUE, 'Illustrative projection only; earnings are not guaranteed.'),
  ('Elite',  5000000,   30, 250000, TRUE, 'Illustrative projection only; earnings are not guaranteed.')
ON CONFLICT (name) DO UPDATE SET
  principal_amount = EXCLUDED.principal_amount,
  duration_days = EXCLUDED.duration_days,
  daily_projection = EXCLUDED.daily_projection,
  is_active = EXCLUDED.is_active,
  terms = EXCLUDED.terms;
