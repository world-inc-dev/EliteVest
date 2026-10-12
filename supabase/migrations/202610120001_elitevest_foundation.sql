-- EliteVest additive database foundation (safe to run more than once).
-- This creates NEW ev_* tables; it does not modify or delete existing tables.
-- Money-related writes must be performed by trusted Supabase Edge Functions only.
create extension if not exists pgcrypto;

create table if not exists public.ev_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  referral_code text unique,
  referred_by uuid references auth.users(id) on delete set null,
  account_status text not null default 'active' check (account_status in ('active','suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ev_packages (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  principal_amount bigint not null check (principal_amount > 0),
  duration_days integer not null default 30 check (duration_days > 0),
  daily_projection bigint not null default 0 check (daily_projection >= 0),
  is_active boolean not null default false,
  terms text not null default 'Illustrative projection only; earnings are not guaranteed.',
  created_at timestamptz not null default now()
);

create table if not exists public.ev_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  currency text not null default 'UGX' check (currency = 'UGX'),
  available_balance bigint not null default 0 check (available_balance >= 0),
  reserved_balance bigint not null default 0 check (reserved_balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.ev_payment_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  package_id uuid not null references public.ev_packages(id) on delete restrict,
  provider text not null check (provider in ('pesajet')),
  provider_reference text unique,
  merchant_reference text not null unique default ('EV-' || replace(gen_random_uuid()::text,'-','')),
  phone_number text not null,
  amount bigint not null check (amount > 0),
  currency text not null default 'UGX' check (currency = 'UGX'),
  status text not null default 'pending' check (status in ('pending','paid','failed','cancelled','expired')),
  provider_transaction_id text unique,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ev_investments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  package_id uuid not null references public.ev_packages(id) on delete restrict,
  payment_order_id uuid not null unique references public.ev_payment_orders(id) on delete restrict,
  principal_amount bigint not null check (principal_amount > 0),
  started_at timestamptz not null default now(),
  matures_at timestamptz not null,
  status text not null default 'active' check (status in ('active','matured','cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists public.ev_wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  investment_id uuid references public.ev_investments(id) on delete restrict,
  payment_order_id uuid references public.ev_payment_orders(id) on delete restrict,
  transaction_type text not null check (transaction_type in ('welcome_bonus','earning','referral_commission','withdrawal','adjustment','deposit')),
  direction text not null check (direction in ('credit','debit')),
  amount bigint not null check (amount > 0),
  currency text not null default 'UGX' check (currency = 'UGX'),
  idempotency_key text not null unique,
  status text not null default 'posted' check (status in ('pending','posted','reversed','failed')),
  description text,
  created_at timestamptz not null default now()
);

create table if not exists public.ev_referral_commissions (
  id uuid primary key default gen_random_uuid(),
  beneficiary_user_id uuid not null references auth.users(id) on delete restrict,
  referred_user_id uuid not null references auth.users(id) on delete restrict,
  payment_order_id uuid not null references public.ev_payment_orders(id) on delete restrict,
  level integer not null check (level between 1 and 3),
  rate_basis_points integer not null check (rate_basis_points in (500,200,100)),
  amount bigint not null check (amount >= 0),
  status text not null default 'pending' check (status in ('pending','posted','reversed')),
  created_at timestamptz not null default now(),
  unique (beneficiary_user_id, payment_order_id, level)
);

create table if not exists public.ev_withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  amount bigint not null check (amount > 0),
  currency text not null default 'UGX' check (currency = 'UGX'),
  network text not null check (network in ('mtn','airtel')),
  phone_number text not null,
  status text not null default 'pending' check (status in ('pending','approved','processing','paid','rejected','failed','cancelled')),
  provider_reference text unique,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.ev_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists ev_payment_orders_user_created_idx on public.ev_payment_orders(user_id, created_at desc);
create index if not exists ev_investments_user_status_idx on public.ev_investments(user_id, status);
create index if not exists ev_wallet_transactions_user_created_idx on public.ev_wallet_transactions(user_id, created_at desc);
create index if not exists ev_withdrawals_user_created_idx on public.ev_withdrawal_requests(user_id, created_at desc);
create index if not exists ev_referral_commissions_beneficiary_idx on public.ev_referral_commissions(beneficiary_user_id, created_at desc);

alter table public.ev_profiles enable row level security;
alter table public.ev_packages enable row level security;
alter table public.ev_wallets enable row level security;
alter table public.ev_payment_orders enable row level security;
alter table public.ev_investments enable row level security;
alter table public.ev_wallet_transactions enable row level security;
alter table public.ev_referral_commissions enable row level security;
alter table public.ev_withdrawal_requests enable row level security;
alter table public.ev_admins enable row level security;

drop policy if exists ev_profiles_read_own on public.ev_profiles;
create policy ev_profiles_read_own on public.ev_profiles for select to authenticated using (user_id = auth.uid());

drop policy if exists ev_packages_read_active on public.ev_packages;
create policy ev_packages_read_active on public.ev_packages for select to anon, authenticated using (is_active = true);

drop policy if exists ev_wallets_read_own on public.ev_wallets;
create policy ev_wallets_read_own on public.ev_wallets for select to authenticated using (user_id = auth.uid());

drop policy if exists ev_payment_orders_read_own on public.ev_payment_orders;
create policy ev_payment_orders_read_own on public.ev_payment_orders for select to authenticated using (user_id = auth.uid());

drop policy if exists ev_investments_read_own on public.ev_investments;
create policy ev_investments_read_own on public.ev_investments for select to authenticated using (user_id = auth.uid());

drop policy if exists ev_wallet_transactions_read_own on public.ev_wallet_transactions;
create policy ev_wallet_transactions_read_own on public.ev_wallet_transactions for select to authenticated using (user_id = auth.uid());

drop policy if exists ev_referral_commissions_read_own on public.ev_referral_commissions;
create policy ev_referral_commissions_read_own on public.ev_referral_commissions for select to authenticated using (beneficiary_user_id = auth.uid());

drop policy if exists ev_withdrawals_read_own on public.ev_withdrawal_requests;
create policy ev_withdrawals_read_own on public.ev_withdrawal_requests for select to authenticated using (user_id = auth.uid());

-- No client-facing policies on ev_admins. Do not allow clients to write financial records.
revoke all on public.ev_profiles, public.ev_packages, public.ev_wallets,
  public.ev_payment_orders, public.ev_investments, public.ev_wallet_transactions,
  public.ev_referral_commissions, public.ev_withdrawal_requests, public.ev_admins
  from anon, authenticated;
grant select on public.ev_packages to anon, authenticated;
grant select on public.ev_profiles, public.ev_wallets, public.ev_payment_orders,
  public.ev_investments, public.ev_wallet_transactions, public.ev_referral_commissions,
  public.ev_withdrawal_requests to authenticated;

-- Intentionally no automatic crediting, package activation, bonuses, or payouts here.
-- Those operations must be implemented in verified, idempotent Edge Functions.
