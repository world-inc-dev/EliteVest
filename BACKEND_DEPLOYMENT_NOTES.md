# EliteVest backend completion checklist

This file is a deployment checklist, not a statement that live payments are enabled.

## Current frontend behavior
- The browser calls the Supabase Edge Function `initiate-elitevest-payment`.
- Package payment is disabled when the selected package has no database ID.
- The UI says package activation must wait for a verified successful-payment webhook.
- Withdrawals are still preview-only in `index.html`.

## Do not enable live deposits until all checks pass
1. Confirm the actual PesaJet API key and webhook secret are configured as Supabase Edge Function secrets. Never place either value in `index.html`, GitHub, logs, or chat.
2. Confirm `initiate-elitevest-payment` uses the authenticated Supabase user from the verified bearer token, loads the package amount from the database (never trusts a browser-supplied amount), creates a unique server-side reference, and stores a pending payment order before calling PesaJet.
3. Confirm the PesaJet webhook validates `X-Webhook-Signature` with the official PesaJet SDK against the exact webhook payload format. Invalid signatures must be rejected.
4. On a verified `payment.completed` event, compare the provider transaction ID, merchant reference, currency, and amount with the pending order. Only then mark it paid and activate the package.
5. Make webhook handling idempotent: a repeated event must never activate twice or credit the wallet twice.
6. Protect all database tables with Row Level Security. Users must not be able to update their own balance, payment status, package activation, referral commission, or withdrawal status directly.
7. Keep withdrawals disabled until a server-side request flow, admin authorization, balance reservation, provider payout result verification, and duplicate-payout protection are implemented and tested.

## PesaJet SDK reference
The published PesaJet SDK quickstart describes the client, `payments.create`, `payment.completed`, and HMAC-SHA256 webhook verification:
https://www.npmjs.com/package/@pesajet/sdk

## Important deployment limitation
Adding files to GitHub does not deploy Supabase Edge Functions or database migrations. Those must be deployed to the Supabase project and tested there. Do not accept live customer money until the checklist is verified end-to-end.