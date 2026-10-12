-- EliteVest withdrawal controls (safe staged rollout).
-- This migration DOES NOT send mobile-money payouts and DOES NOT mint projected earnings.
-- Run only after reviewing the SQL. Real payouts require a verified provider callback.

CREATE OR REPLACE FUNCTION public.ev_request_withdrawal(
  p_amount bigint,
  p_network text,
  p_phone_number text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_wallet public.ev_wallets%ROWTYPE;
  v_request_id uuid;
  v_network text := lower(trim(coalesce(p_network, '')));
  v_phone text := trim(coalesce(p_phone_number, ''));
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Withdrawal amount must be greater than zero';
  END IF;
  IF v_network NOT IN ('mtn', 'airtel') THEN
    RAISE EXCEPTION 'Network must be mtn or airtel';
  END IF;
  IF length(v_phone) < 9 OR length(v_phone) > 16
     OR v_phone !~ '^[+0-9 -]+$' THEN
    RAISE EXCEPTION 'Enter a valid mobile-money phone number';
  END IF;

  SELECT * INTO v_wallet
  FROM public.ev_wallets
  WHERE user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet not found';
  END IF;
  IF v_wallet.available_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient available balance';
  END IF;

  UPDATE public.ev_wallets
  SET available_balance = available_balance - p_amount,
      reserved_balance = reserved_balance + p_amount,
      updated_at = now()
  WHERE user_id = v_user_id;

  INSERT INTO public.ev_withdrawal_requests
    (user_id, amount, currency, network, phone_number, status)
  VALUES
    (v_user_id, p_amount, 'UGX', v_network, v_phone, 'pending')
  RETURNING id INTO v_request_id;

  RETURN v_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.ev_admin_review_withdrawal(
  p_withdrawal_id uuid,
  p_approve boolean
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_req public.ev_withdrawal_requests%ROWTYPE;
BEGIN
  IF v_admin_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.ev_admins WHERE user_id = v_admin_id
  ) THEN
    RAISE EXCEPTION 'Admin authorization required';
  END IF;

  SELECT * INTO v_req
  FROM public.ev_withdrawal_requests
  WHERE id = p_withdrawal_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Withdrawal request not found';
  END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'Only pending withdrawals can be reviewed';
  END IF;

  IF p_approve THEN
    UPDATE public.ev_withdrawal_requests
    SET status = 'approved', reviewed_by = v_admin_id, reviewed_at = now()
    WHERE id = p_withdrawal_id;
    RETURN 'approved; payout has NOT been sent';
  END IF;

  UPDATE public.ev_wallets
  SET available_balance = available_balance + v_req.amount,
      reserved_balance = reserved_balance - v_req.amount,
      updated_at = now()
  WHERE user_id = v_req.user_id
    AND reserved_balance >= v_req.amount;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet reservation mismatch; manual review required';
  END IF;

  UPDATE public.ev_withdrawal_requests
  SET status = 'rejected', reviewed_by = v_admin_id, reviewed_at = now()
  WHERE id = p_withdrawal_id;

  RETURN 'rejected; reserved balance released';
END;
$$;

-- This finalizer is for a trusted server-side provider callback only.
-- The provider reference must be the actual payout transaction reference.
CREATE OR REPLACE FUNCTION public.ev_finalize_withdrawal_payout(
  p_withdrawal_id uuid,
  p_provider_reference text,
  p_success boolean
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req public.ev_withdrawal_requests%ROWTYPE;
BEGIN
  IF p_withdrawal_id IS NULL OR p_success IS NULL THEN
    RAISE EXCEPTION 'Withdrawal ID and outcome are required';
  END IF;
  IF p_success AND length(trim(coalesce(p_provider_reference, ''))) = 0 THEN
    RAISE EXCEPTION 'Verified provider payout reference is required';
  END IF;

  SELECT * INTO v_req
  FROM public.ev_withdrawal_requests
  WHERE id = p_withdrawal_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Withdrawal request not found';
  END IF;
  IF v_req.status NOT IN ('approved', 'processing') THEN
    IF v_req.status = 'paid' AND p_success THEN
      RETURN 'already paid';
    END IF;
    RAISE EXCEPTION 'Withdrawal is not approved for payout finalization';
  END IF;

  IF p_success THEN
    UPDATE public.ev_wallets
    SET reserved_balance = reserved_balance - v_req.amount,
        updated_at = now()
    WHERE user_id = v_req.user_id
      AND reserved_balance >= v_req.amount;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Wallet reservation mismatch; manual review required';
    END IF;

    INSERT INTO public.ev_wallet_transactions
      (user_id, transaction_type, direction, amount, currency,
       idempotency_key, status, description)
    VALUES
      (v_req.user_id, 'withdrawal', 'debit', v_req.amount, 'UGX',
       'withdrawal:' || v_req.id::text, 'posted',
       'Provider-confirmed mobile-money payout')
    ON CONFLICT (idempotency_key) DO NOTHING;

    UPDATE public.ev_withdrawal_requests
    SET status = 'paid',
        provider_reference = trim(p_provider_reference),
        paid_at = now()
    WHERE id = p_withdrawal_id;

    RETURN 'paid; provider confirmation recorded';
  END IF;

  UPDATE public.ev_wallets
  SET available_balance = available_balance + v_req.amount,
      reserved_balance = reserved_balance - v_req.amount,
      updated_at = now()
  WHERE user_id = v_req.user_id
    AND reserved_balance >= v_req.amount;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet reservation mismatch; manual review required';
  END IF;

  UPDATE public.ev_withdrawal_requests
  SET status = 'failed'
  WHERE id = p_withdrawal_id;

  RETURN 'failed; reserved balance returned to available balance';
END;
$$;

REVOKE ALL ON FUNCTION public.ev_request_withdrawal(bigint, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ev_request_withdrawal(bigint, text, text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.ev_admin_review_withdrawal(uuid, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ev_admin_review_withdrawal(uuid, boolean)
  TO authenticated;

REVOKE ALL ON FUNCTION public.ev_finalize_withdrawal_payout(uuid, text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ev_finalize_withdrawal_payout(uuid, text, boolean)
  TO service_role;
