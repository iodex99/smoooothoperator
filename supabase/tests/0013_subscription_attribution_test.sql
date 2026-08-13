-- pgTAP for migration 0015: the payment path the audit found unusable.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', 'b1111111-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'sub-a@example.com'),
    ('00000000-0000-0000-0000-000000000000', 'b2222222-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'sub-b@example.com');

-- ── The webhook's exact write must succeed ────────────────────────────────
-- It previously omitted user_id and latest_transaction_id, both NOT NULL,
-- so EVERY notification failed the insert and Apple eventually gave up.
select lives_ok(
    $$ insert into public.subscriptions
         (original_transaction_id, latest_transaction_id, user_id, product_id,
          status, expires_at, environment)
       values ('APPLE-1', 'APPLE-1', null, 'smooooth.pro.monthly',
               'active', now() + interval '30 days', 'production') $$,
    'an unattributed notification row can be written'
);

select lives_ok(
    $$ insert into public.subscriptions
         (original_transaction_id, latest_transaction_id, user_id, product_id,
          status, expires_at, environment)
       values ('APPLE-2', 'APPLE-2', 'b1111111-0000-0000-0000-000000000001',
               'smooooth.pro.yearly', 'active', now() + interval '365 days', 'production') $$,
    'an attributed notification row can be written'
);

-- ── Entitlement rules ─────────────────────────────────────────────────────
select ok(
    public.has_active_pro('b1111111-0000-0000-0000-000000000001'),
    'a live production subscription grants Pro'
);

insert into public.subscriptions
    (original_transaction_id, latest_transaction_id, user_id, product_id,
     status, expires_at, environment)
values ('APPLE-SANDBOX', 'APPLE-SANDBOX', 'b2222222-0000-0000-0000-000000000002',
        'smooooth.pro.monthly', 'active', now() + interval '30 days', 'sandbox');

select ok(
    not public.has_active_pro('b2222222-0000-0000-0000-000000000002'),
    'a SANDBOX subscription never grants production Pro'
);

select ok(
    public.has_active_pro_in('b2222222-0000-0000-0000-000000000002', 'sandbox'),
    'but it does grant Pro in the sandbox environment'
);

-- A null expiry used to mean "never expires" — a malformed notification
-- could grant permanent Pro.
update public.subscriptions set expires_at = null
 where original_transaction_id = 'APPLE-2';

select ok(
    not public.has_active_pro('b1111111-0000-0000-0000-000000000001'),
    'an unknown expiry is NOT treated as forever'
);

-- ── Claiming ──────────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "b2222222-0000-0000-0000-000000000002", "role": "authenticated"}', true);
set local role authenticated;

select ok(
    public.claim_subscription('APPLE-1'),
    'a signed-in user can claim an unattributed subscription'
);

select ok(
    not public.claim_subscription('APPLE-2'),
    'but can NEVER claim one that already belongs to someone else'
);

reset role;
select * from finish();
rollback;
