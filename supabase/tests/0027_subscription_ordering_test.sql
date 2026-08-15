-- Apple retries notifications for days and does not promise order. The
-- webhook used to write each one straight in with a merge-duplicates upsert,
-- which is idempotent but not order-independent — and those are different
-- properties. Two things could go wrong, one costing money and one costing
-- a paying customer their subscription.

begin;
select plan(9);

insert into auth.users (id, email) values
    ('5b000001-0000-4000-8000-000000000001', 'subscriber@test.local'),
    ('5b000002-0000-4000-8000-000000000002', 'opportunist@test.local');

-- ── 1. a refunded subscription must not come back to life ─────────────────

select is(
    public.record_subscription_notification(
        'txn-refund-case', 'txn-1', '5b000001-0000-4000-8000-000000000001',
        'smooooth.pro.monthly', 'active', now() + interval '30 days',
        'production', now() - interval '2 days'),
    'applied',
    'the renewal is recorded'
);

select ok(
    public.has_active_pro_in('5b000001-0000-4000-8000-000000000001', 'production'),
    'and the subscriber has Pro'
);

select is(
    public.record_subscription_notification(
        'txn-refund-case', 'txn-1', '5b000001-0000-4000-8000-000000000001',
        'smooooth.pro.monthly', 'revoked', now() + interval '30 days',
        'production', now() - interval '1 day'),
    'applied',
    'the refund arrives a day later and is recorded'
);

select ok(
    not public.has_active_pro_in('5b000001-0000-4000-8000-000000000001', 'production'),
    'Pro is gone'
);

-- Apple retries the ORIGINAL renewal. It is older than the refund.
select is(
    public.record_subscription_notification(
        'txn-refund-case', 'txn-1', '5b000001-0000-4000-8000-000000000001',
        'smooooth.pro.monthly', 'active', now() + interval '30 days',
        'production', now() - interval '2 days'),
    'ignored_stale',
    'a retry of the earlier renewal is refused as stale'
);

select ok(
    not public.has_active_pro_in('5b000001-0000-4000-8000-000000000001', 'production'),
    'the refund stands — a retried renewal used to hand Pro back to a '
    'refunded customer for the rest of the period they were refunded for'
);

-- ── 2. a renewal must not unlink the subscriber ───────────────────────────
--
-- appAccountToken is read from signedTransactionInfo. A notification
-- carrying only signedRenewalInfo has no transaction to read it from, so it
-- arrives with no user — and used to write that NULL straight over the
-- attributed subscriber.

select is(
    public.record_subscription_notification(
        'txn-attribution', 'txn-2', '5b000001-0000-4000-8000-000000000001',
        'smooooth.pro.yearly', 'active', now() + interval '365 days',
        'production', now() - interval '10 days'),
    'applied',
    'the purchase attributes the subscription'
);

-- a later notification with no transaction info: p_user_id is NULL
select is(
    public.record_subscription_notification(
        'txn-attribution', 'txn-3', null,
        'smooooth.pro.yearly', 'active', now() + interval '365 days',
        'production', now() - interval '1 day'),
    'applied',
    'a renewal with no attribution is still applied'
);

select is(
    (select user_id from public.subscriptions
      where original_transaction_id = 'txn-attribution'),
    '5b000001-0000-4000-8000-000000000001'::uuid,
    'but the subscriber is still attached — a NULL from a renewal used to '
    'erase them, unentitling a paying customer and leaving the row open for '
    'anyone else to claim by transaction id'
);

select * from finish();
rollback;
