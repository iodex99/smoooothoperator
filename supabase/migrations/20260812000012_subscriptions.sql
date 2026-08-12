-- 0012: subscriptions — server-side mirror of App Store subscription state
-- (spec §§73, M4). Rows are written ONLY by the service role from verified
-- App Store Server API data / server notifications; the client NEVER
-- self-reports entitlement (no fake client-side verification, spec §73).

create table public.subscriptions (
    id uuid primary key default extensions.gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    product_id text not null check (product_id in (
        'smooooth.pro.weekly', 'smooooth.pro.monthly', 'smooooth.pro.yearly'
    )),
    -- App Store originalTransactionId: the stable subscription identity.
    original_transaction_id text not null unique,
    latest_transaction_id text not null,
    status text not null check (status in (
        'active', 'in_grace_period', 'in_billing_retry', 'expired', 'revoked'
    )),
    expires_at timestamptz,
    environment text not null default 'production'
        check (environment in ('sandbox', 'production')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index subscriptions_user_idx on public.subscriptions (user_id, status);

alter table public.subscriptions enable row level security;

grant select on public.subscriptions to authenticated;
grant all on public.subscriptions to service_role;

-- Users see only their own subscription state.
create policy "users see own subscriptions"
    on public.subscriptions for select
    using (user_id = (select auth.uid()));

create trigger subscriptions_set_updated_at
    before update on public.subscriptions
    for each row
    execute function public.set_updated_at();

-- Entitlement check used by server logic (and exposed to the client for
-- display; the server re-checks on every Pro-gated operation).
create or replace function public.has_active_pro(p_user uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
    select exists (
        select 1 from public.subscriptions s
        where s.user_id = p_user
          and s.status in ('active', 'in_grace_period')
          and (s.expires_at is null or s.expires_at > now())
    );
$$;

grant execute on function public.has_active_pro(uuid) to authenticated, service_role;
