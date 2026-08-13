-- 0015: make subscriptions actually writable, and entitlement actually safe.
--
-- Audit 2026-08-13 (payments): the App Store notification webhook could
-- never have succeeded. It writes five columns; `user_id` and
-- `latest_transaction_id` are both NOT NULL and were never among them, so
-- every notification failed the insert and returned 500. Apple retried and
-- gave up. Nobody would ever have been entitled.
--
-- Worse, nothing linked Apple's transaction to a Supabase user at all. That
-- link is `appAccountToken` — a UUID the CLIENT attaches to the purchase and
-- Apple echoes back in the signed transaction. The app now sends its user id
-- there; this migration makes the schema able to receive it, including the
-- case where a purchase arrives before we know who made it.

-- ── 1. A notification may arrive before attribution is possible ───────────
-- Apple sends notifications for purchases made outside the app (promo codes,
-- another device, family sharing) where appAccountToken may be absent. Those
-- rows must still land, unattributed, rather than being lost.
alter table public.subscriptions
    alter column user_id drop not null;

alter table public.subscriptions
    alter column latest_transaction_id drop not null;

comment on column public.subscriptions.user_id is
    'The Supabase user, from the purchase''s appAccountToken. NULL = an Apple notification we could not attribute yet; the client claims it on next launch (audit 2026-08-13).';

-- ── 2. Sandbox must never grant production entitlement ────────────────────
-- `environment` was written by the webhook and read by nothing, so any
-- TestFlight tester or sandbox Apple ID would have received full Pro.
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
          -- An auto-renewable subscription ALWAYS has an expiry. A null one
          -- means we never learned it, and "unknown" must not mean "forever":
          -- a malformed notification could otherwise grant permanent Pro.
          and s.expires_at is not null
          and s.expires_at > now()
          and s.environment = 'production'
    );
$$;

grant execute on function public.has_active_pro(uuid) to authenticated, service_role;

-- Sandbox builds need the same check against sandbox rows, so TestFlight can
-- be tested without opening a production hole.
create or replace function public.has_active_pro_in(p_user uuid, p_environment text)
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
          and s.expires_at is not null
          and s.expires_at > now()
          and s.environment = p_environment
    );
$$;

grant execute on function public.has_active_pro_in(uuid, text)
    to authenticated, service_role;

-- ── 3. Claiming an unattributed subscription ──────────────────────────────
-- The client knows its own originalTransactionId from StoreKit. This lets a
-- signed-in user adopt a row the webhook could not attribute — but ONLY a
-- row that nobody owns, so it can never steal someone else's subscription.
create or replace function public.claim_subscription(p_original_transaction_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := (select auth.uid());
    claimed integer;
begin
    if me is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;
    update public.subscriptions
       set user_id = me
     where original_transaction_id = p_original_transaction_id
       and user_id is null;
    get diagnostics claimed = row_count;
    return claimed > 0;
end;
$$;

revoke all on function public.claim_subscription(text) from public, anon;
grant execute on function public.claim_subscription(text) to authenticated;
