-- EliteVest platform-wide financial report.
-- Apply after the EliteVest foundation and withdrawal migrations.
-- The function returns aggregates only; it does not expose member-level financial records.
-- Ensure the intended admin account exists in public.ev_admins before using this report.

CREATE OR REPLACE FUNCTION public.ev_admin_financial_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.ev_admins WHERE user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Admin authorization required';
  END IF;

  SELECT jsonb_build_object(
    'paid_payment_count', (SELECT count(*) FROM public.ev_payment_orders WHERE status = 'paid'),
    'paid_payment_amount', (SELECT coalesce(sum(amount), 0) FROM public.ev_payment_orders WHERE status = 'paid'),
    'active_investment_count', (SELECT count(*) FROM public.ev_investments WHERE status = 'active'),
    'active_principal_amount', (SELECT coalesce(sum(principal_amount), 0) FROM public.ev_investments WHERE status = 'active'),
    'welcome_bonus_amount', (
      SELECT coalesce(sum(amount), 0) FROM public.ev_wallet_transactions
      WHERE transaction_type = 'welcome_bonus' AND direction = 'credit' AND status = 'posted'
    ),
    'earning_amount', (
      SELECT coalesce(sum(amount), 0) FROM public.ev_wallet_transactions
      WHERE transaction_type = 'earning' AND direction = 'credit' AND status = 'posted'
    ),
    'referral_posted_count', (SELECT count(*) FROM public.ev_referral_commissions WHERE status = 'posted'),
    'referral_posted_amount', (SELECT coalesce(sum(amount), 0) FROM public.ev_referral_commissions WHERE status = 'posted'),
    'referral_pending_count', (SELECT count(*) FROM public.ev_referral_commissions WHERE status = 'pending'),
    'referral_pending_amount', (SELECT coalesce(sum(amount), 0) FROM public.ev_referral_commissions WHERE status = 'pending'),
    'withdrawal_paid_count', (SELECT count(*) FROM public.ev_withdrawal_requests WHERE status = 'paid'),
    'withdrawal_paid_amount', (SELECT coalesce(sum(amount), 0) FROM public.ev_withdrawal_requests WHERE status = 'paid'),
    'withdrawal_pending_count', (SELECT count(*) FROM public.ev_withdrawal_requests WHERE status = 'pending'),
    'withdrawal_pending_amount', (SELECT coalesce(sum(amount), 0) FROM public.ev_withdrawal_requests WHERE status = 'pending'),
    'withdrawal_approved_count', (SELECT count(*) FROM public.ev_withdrawal_requests WHERE status IN ('approved','processing')),
    'withdrawal_approved_amount', (SELECT coalesce(sum(amount), 0) FROM public.ev_withdrawal_requests WHERE status IN ('approved','processing')),
    'withdrawal_rejected_count', (SELECT count(*) FROM public.ev_withdrawal_requests WHERE status = 'rejected'),
    'withdrawal_failed_count', (SELECT count(*) FROM public.ev_withdrawal_requests WHERE status = 'failed')
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.ev_admin_financial_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ev_admin_financial_report() TO authenticated;

-- If the admin user already exists, register it for this function and the
-- existing withdrawal-review function. If it does not exist yet, run this
-- insert again after that account has been created.
INSERT INTO public.ev_admins (user_id)
SELECT id FROM auth.users
WHERE lower(email) = lower('worldbridan3@gmail.com')
ON CONFLICT (user_id) DO NOTHING;
