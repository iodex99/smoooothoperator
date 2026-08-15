-- 0029: two ways a paying customer could lose their subscription, and one
-- way a refunded one could keep it.
--
-- The App Store webhook wrote every notification straight into the
-- subscriptions table with an unconditional merge:
--
--   POST /subscriptions?on_conflict=original_transaction_id
--   Prefer: resolution=merge-duplicates
--   { user_id: appAccountToken ?? null, status: ..., expires_at: ... }
--
-- The comment above it said "idempotent by construction, which matters
-- because Apple retries notifications". Idempotent it was. Order-independent
-- it was not, and those are different properties.
--
-- ── 1. A REFUNDED SUBSCRIPTION COULD COME BACK TO LIFE ────────────────────
--
-- Apple retries a notification for up to several days and states plainly
-- that notifications can arrive OUT OF ORDER. So:
--
--   t1  DID_RENEW  -> status=active,  expires_at = next month
--   t2  REFUND     -> status=revoked, expires_at unchanged (still future)
--   t3  Apple retries the t1 DID_RENEW
--       -> status=active, expires_at still in the future
--
-- and `has_active_pro_in` asks exactly:
--
--   status in ('active','in_grace_period') and expires_at > now()
--
-- so at t3 the refunded customer has Pro again, indefinitely, until the
-- period they were refunded for finally lapses. Nothing in the pipeline
-- looked at WHEN a notification was signed.
--
-- ── 2. A RENEWAL COULD UNLINK A SUBSCRIBER FROM THEIR OWN SUBSCRIPTION ────
--
-- `user_id` was written as `appAccountToken ?? null` on EVERY notification.
-- appAccountToken is read from `signedTransactionInfo`, and notifications
-- that carry only `signedRenewalInfo` have no transaction to read it from —
-- so those wrote NULL straight over the attributed user.
--
-- The subscriber is then unentitled (has_active_pro_in matches on user_id)
-- until the app happens to call `claim_subscription` again. Worse, while
-- user_id is NULL the row is claimable, and `claim_subscription` claims by
-- original_transaction_id alone — so the window is not merely a lapse in
-- service, it is a window in which somebody else's subscription can be
-- claimed by whoever presents that id.
--
-- ── the fix ───────────────────────────────────────────────────────────────
--
-- One function, called by the webhook instead of a raw upsert, with the two
-- guards the table always needed:
--
--   * an older notification never overwrites a newer one, and
--   * attribution is never downgraded from a user to nobody.

alter table public.subscriptions
    add column if not exists notified_at timestamptz;

comment on column public.subscriptions.notified_at is
    'signedDate of the most recent App Store notification applied to this '
    'row. Apple delivers out of order and retries for days; this is what '
    'makes a late arrival lose to the state it would otherwise undo.';

-- Existing rows predate the column. NULL sorts as "older than anything",
-- which is what we want: the first real notification wins.

create or replace function public.record_subscription_notification(
    p_original_transaction_id text,
    p_latest_transaction_id text,
    p_user_id uuid,
    p_product_id text,
    p_status text,
    p_expires_at timestamptz,
    p_environment text,
    p_notified_at timestamptz
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    applied integer;
begin
    insert into public.subscriptions (
        original_transaction_id, latest_transaction_id, user_id,
        product_id, status, expires_at, environment, notified_at
    ) values (
        p_original_transaction_id, p_latest_transaction_id, p_user_id,
        p_product_id, p_status, p_expires_at,
        coalesce(p_environment, 'production'), p_notified_at
    )
    on conflict (original_transaction_id) do update
    set latest_transaction_id = excluded.latest_transaction_id,
        -- Attribution only ever improves. A notification that cannot say who
        -- the subscriber is must not be allowed to say it is nobody.
        user_id = coalesce(excluded.user_id, public.subscriptions.user_id),
        product_id = excluded.product_id,
        status = excluded.status,
        expires_at = excluded.expires_at,
        environment = excluded.environment,
        notified_at = excluded.notified_at
    -- The whole point. A retry of last week's DID_RENEW arriving after this
    -- week's REFUND loses, and the refund stands.
    where public.subscriptions.notified_at is null
       or excluded.notified_at is null
       or excluded.notified_at >= public.subscriptions.notified_at;

    get diagnostics applied = row_count;
    return case when applied > 0 then 'applied' else 'ignored_stale' end;
end;
$$;

comment on function public.record_subscription_notification(
    text, text, uuid, text, text, timestamptz, text, timestamptz) is
    'Applies one App Store notification. Refuses to let an older '
    'notification overwrite a newer one, and never downgrades a known '
    'subscriber to NULL. Service role only — this is the money table.';

revoke all on function public.record_subscription_notification(
    text, text, uuid, text, text, timestamptz, text, timestamptz) from public, anon, authenticated;
grant execute on function public.record_subscription_notification(
    text, text, uuid, text, text, timestamptz, text, timestamptz) to service_role;
