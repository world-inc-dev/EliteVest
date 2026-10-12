-- EliteVest verified-payment finalization.
-- This is a server-only helper. It must be called ONLY after the PesaJet
-- webhook has verified the provider's signature and confirmed the exact amount.
-- It does not generate daily earnings or send withdrawals.

CREATE OR REPLACE FUNCTION public.ev_finalize_verified_payment(
  p_payment_order_id uuid,
  p_provider_transaction_id text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.ev_payment_orders%ROWTYPE;
  v_package public.ev_packages%ROWTYPE;
  v_investment_id uuid;
  v_bonus_ledger_id uuid;
  v_referrer uuid;
  v_level integer;
  v_rate integer;
  v_commission_amount bigint;
  v_beneficiary uuid;
BEGIN
  IF p_payment_order_id IS NULL
     OR p_provider_transaction_id IS NULL
     OR length(trim(p_provider_transaction_id)) = 0 THEN
    RAISE EXCEPTION 'Payment order and provider transaction ID are required';
  END IF;

  SELECT * INTO v_order
  FROM public.ev_payment_orders
  WHERE id = p_payment_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment order not found';
  END IF;

  -- Idempotent retry after a previously completed webhook.
  IF v_order.status = 'paid' THEN
    SELECT id INTO v_investment_id
    FROM public.ev_investments
    WHERE payment_order_id = v_order.id;
    IF v_investment_id IS NOT NULL THEN
      RETURN v_investment_id;
    END IF;
    RAISE EXCEPTION 'Order is paid but investment record is missing; review manually';
  END IF;

  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION 'Payment order is not pending';
  END IF;

  SELECT * INTO v_package
  FROM public.ev_packages
  WHERE id = v_order.package_id
  FOR SHARE;

  IF NOT FOUND OR NOT v_package.is_active THEN
    RAISE EXCEPTION 'Package not found or inactive';
  END IF;

  IF v_order.amount <> v_package.principal_amount THEN
    RAISE EXCEPTION 'Payment amount does not match package price';
  END IF;

  UPDATE public.ev_payment_orders
  SET status = 'paid',
      provider_transaction_id = trim(p_provider_transaction_id),
      verified_at = now(),
      updated_at = now()
  WHERE id = v_order.id;

  INSERT INTO public.ev_investments
    (user_id, package_id, payment_order_id, principal_amount, started_at, matures_at, status)
  VALUES
    (v_order.user_id, v_package.id, v_order.id, v_order.amount, now(),
     now() + make_interval(days => v_package.duration_days), 'active')
  RETURNING id INTO v_investment_id;

  -- Ensure a wallet exists; bonus is credited once per user after first
  -- successfully verified package payment. Never from the browser.
  INSERT INTO public.ev_wallets(user_id, currency, available_balance, reserved_balance)
  VALUES (v_order.user_id, 'UGX', 0, 0)
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.ev_wallet_transactions
    (user_id, investment_id, payment_order_id, transaction_type, direction,
     amount, currency, idempotency_key, status, description)
  VALUES
    (v_order.user_id, v_investment_id, v_order.id, 'welcome_bonus', 'credit',
     5000, 'UGX', 'welcome-bonus:' || v_order.user_id::text, 'posted',
     'One-time welcome bonus after verified package activation')
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_bonus_ledger_id;

  IF v_bonus_ledger_id IS NOT NULL THEN
    UPDATE public.ev_wallets
    SET available_balance = available_balance + 5000,
        updated_at = now()
    WHERE user_id = v_order.user_id;
  END IF;

  -- Record proposed referral commissions as PENDING obligations only.
  -- They are not spendable wallet funds and are not automatically paid.
  SELECT referred_by INTO v_referrer
  FROM public.ev_profiles
  WHERE user_id = v_order.user_id;

  FOR v_level IN 1..3 LOOP
    EXIT WHEN v_referrer IS NULL;

    v_rate := CASE v_level WHEN 1 THEN 500 WHEN 2 THEN 200 ELSE 100 END;
    v_commission_amount := floor(v_order.amount::numeric * v_rate / 10000)::bigint;

    INSERT INTO public.ev_referral_commissions
      (beneficiary_user_id, referred_user_id, payment_order_id, level,
       rate_basis_points, amount, status)
    VALUES
      (v_referrer, v_order.user_id, v_order.id, v_level,
       v_rate, v_commission_amount, 'pending')
    ON CONFLICT (beneficiary_user_id, payment_order_id, level) DO NOTHING;

    SELECT referred_by INTO v_referrer
    FROM public.ev_profiles
    WHERE user_id = v_referrer;
  END LOOP;

  RETURN v_investment_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ev_finalize_verified_payment(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ev_finalize_verified_payment(uuid, text)
  TO service_role;
