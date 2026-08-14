-- The entitlement rule decides who is a paying customer, and it had been
-- written out twice. It has already been wrong once — sandbox granted
-- production Pro, a null expiry granted permanent Pro — so these tests pin
-- the behaviour that matters and prove the two entry points agree.

begin;
select plan(11);

insert into auth.users (id, email) values
    ('a1000001-a000-4000-8000-000000000001', 'payer@test.local'),
    ('a1000002-b000-4000-8000-000000000002', 'freeloader@test.local');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status
) values (
    'a1000003-c000-4000-8000-000000000003', 'Garage Compare Course', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-158.5, -30.5),
        extensions.st_makepoint(-158.4, -30.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-158.5, -30.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-158.4, -30.5), 4326)::extensions.geography,
    'active'
);

-- ── the entitlement rule, once ────────────────────────────────────────────

insert into public.subscriptions (
    user_id, product_id, original_transaction_id, latest_transaction_id,
    status, environment, expires_at
) values
    ('a1000001-a000-4000-8000-000000000001', 'smooooth.pro.monthly',
     'ent-prod', 'ent-prod', 'active', 'production', now() + interval '30 days');

select ok(
    public.has_active_pro('a1000001-a000-4000-8000-000000000001'),
    'a live production subscription is Pro'
);

select is(
    public.has_active_pro('a1000001-a000-4000-8000-000000000001'),
    public.has_active_pro_in('a1000001-a000-4000-8000-000000000001', 'production'),
    'the two entry points agree — there is one rule, not two'
);

select ok(
    not public.has_active_pro('a1000002-b000-4000-8000-000000000002'),
    'somebody with no subscription is not Pro'
);

-- Sandbox is a test, not a purchase. This was a real defect once.
update public.subscriptions set environment = 'sandbox' where original_transaction_id = 'ent-prod';
select ok(
    not public.has_active_pro('a1000001-a000-4000-8000-000000000001'),
    'a SANDBOX subscription never grants production Pro'
);

-- A null expiry once granted Pro forever.
update public.subscriptions
   set environment = 'production', expires_at = null
 where original_transaction_id = 'ent-prod';
select ok(
    not public.has_active_pro('a1000001-a000-4000-8000-000000000001'),
    'a null expiry is not a permanent subscription'
);

update public.subscriptions
   set expires_at = now() - interval '1 day'
 where original_transaction_id = 'ent-prod';
select ok(
    not public.has_active_pro('a1000001-a000-4000-8000-000000000001'),
    'an expired subscription is not Pro'
);

update public.subscriptions
   set status = 'in_grace_period', expires_at = now() + interval '3 days'
 where original_transaction_id = 'ent-prod';
select ok(
    public.has_active_pro('a1000001-a000-4000-8000-000000000001'),
    'grace period is still a paying customer'
);

-- ── the garage comparison ─────────────────────────────────────────────────

set local role postgres;
update public.subscriptions set status = 'active' where original_transaction_id = 'ent-prod';

insert into public.vehicles (id, user_id, name, is_default) values
    ('a1000004-d000-4000-8000-000000000004', 'a1000001-a000-4000-8000-000000000001', 'The Golf', true),
    ('a1000005-e000-4000-8000-000000000005', 'a1000001-a000-4000-8000-000000000001', 'Sunday car', false),
    ('a1000006-f000-4000-8000-000000000006', 'a1000001-a000-4000-8000-000000000001', 'Never driven', false);

insert into public.runs (
    id, user_id, course_id, vehicle_id, status, verification, score,
    duration_seconds, started_at, completed_at
) values
    ('a1000007-1000-4000-8000-000000000007', 'a1000001-a000-4000-8000-000000000001',
     'a1000003-c000-4000-8000-000000000003', 'a1000004-d000-4000-8000-000000000004',
     'scored', 'verified', 8200, 190, now(), now()),
    ('a1000008-2000-4000-8000-000000000008', 'a1000001-a000-4000-8000-000000000001',
     'a1000003-c000-4000-8000-000000000003', 'a1000005-e000-4000-8000-000000000005',
     'scored', 'verified', 9100, 175, now(), now());

set local role authenticated;
set local request.jwt.claims = '{"sub":"a1000001-a000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select vehicle_name from public.my_vehicle_bests('a1000003-c000-4000-8000-000000000003') limit 1),
    'Sunday car',
    'the fastest car on this road comes first — that is the whole question'
);

select is(
    (select count(*) from public.my_vehicle_bests('a1000003-c000-4000-8000-000000000003')),
    3::bigint,
    'a car never driven here is still listed, so the garage is complete'
);

select is(
    (select best_score from public.my_vehicle_bests('a1000003-c000-4000-8000-000000000003')
      where vehicle_name = 'Never driven'),
    null,
    'and it honestly reports no time rather than a zero'
);

-- ── it is my garage, not everyone's ───────────────────────────────────────

set local request.jwt.claims = '{"sub":"a1000002-b000-4000-8000-000000000002","role":"authenticated"}';
select is(
    (select count(*) from public.my_vehicle_bests('a1000003-c000-4000-8000-000000000003')),
    0::bigint,
    'another driver sees none of my cars'
);

select * from finish();
rollback;
