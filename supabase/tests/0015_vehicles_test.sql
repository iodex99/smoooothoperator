-- pgTAP for migration 0017: the garage.
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', 'f1111111-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'garage-free@example.com'),
    ('00000000-0000-0000-0000-000000000000', 'f2222222-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'garage-pro@example.com'),
    ('00000000-0000-0000-0000-000000000000', 'f3333333-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'garage-other@example.com');

-- The Pro driver has a live production subscription.
insert into public.subscriptions
    (original_transaction_id, latest_transaction_id, user_id, product_id,
     status, expires_at, environment)
values ('GARAGE-PRO', 'GARAGE-PRO', 'f2222222-0000-0000-0000-000000000002',
        'smooooth.pro.yearly', 'active', now() + interval '300 days', 'production');

insert into public.courses
    (id, name, creator_id, country, distance_meters, difficulty, turn_count,
     geometry, start_point, finish_point, visibility, status)
values ('cafe0000-0000-0000-0000-000000000001', 'Garage Course', null, 'US', 5000, 3, 10,
        extensions.st_geogfromtext('LINESTRING(-118.5 34.0, -118.48 34.02)'),
        extensions.st_geogfromtext('POINT(-118.5 34.0)'),
        extensions.st_geogfromtext('POINT(-118.48 34.02)'), 'public', 'active');

select has_table('public', 'vehicles', 'vehicles table exists');
select ok(
    (select relrowsecurity from pg_class where oid = 'public.vehicles'::regclass),
    'RLS on vehicles'
);

-- ── Free tier: one car ────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "f1111111-0000-0000-0000-000000000001", "role": "authenticated"}', true);
set local role authenticated;

select lives_ok(
    $$ insert into public.vehicles (user_id, name, is_default)
       values ('f1111111-0000-0000-0000-000000000001', 'The Golf', true) $$,
    'a free driver gets their first car'
);

select throws_ok(
    $$ insert into public.vehicles (user_id, name)
       values ('f1111111-0000-0000-0000-000000000001', 'The Second Car') $$,
    '54000',
    null,
    'but the second car needs Pro'
);

-- ── Pro: a garage ─────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "f2222222-0000-0000-0000-000000000002", "role": "authenticated"}', true);

select lives_ok(
    $$ insert into public.vehicles (user_id, name, make, model, year, is_default)
       values ('f2222222-0000-0000-0000-000000000002', 'The Civic', 'Honda', 'Civic Type R', 2023, true) $$,
    'a Pro driver adds a car'
);
select lives_ok(
    $$ insert into public.vehicles (user_id, name, make, model)
       values ('f2222222-0000-0000-0000-000000000002', 'The Miata', 'Mazda', 'MX-5') $$,
    'and another, and another'
);

-- ── One default per driver ────────────────────────────────────────────────
select throws_ok(
    $$ update public.vehicles set is_default = true
        where user_id = 'f2222222-0000-0000-0000-000000000002' and name = 'The Miata' $$,
    '23505',
    null,
    'two default cars is not a state a driver can be in'
);

-- ── Nobody drives someone else's car ──────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "f3333333-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select is(
    (select count(*)::int from public.vehicles),
    0,
    'a driver cannot see another driver''s garage'
);

select throws_ok(
    $$ insert into public.runs (user_id, course_id, status, started_at, vehicle_id)
       select 'f3333333-0000-0000-0000-000000000003',
              'cafe0000-0000-0000-0000-000000000001', 'recording', now(), v.id
         from public.vehicles v limit 1 $$,
    null,
    null,
    'a run cannot claim a car that is not yours'
);

reset role;

-- ── Deleting a car keeps its drives ───────────────────────────────────────
insert into public.runs (id, user_id, course_id, status, started_at, vehicle_id, verification, score, duration_seconds)
select 'ababab00-0000-0000-0000-000000000001', 'f2222222-0000-0000-0000-000000000002',
       'cafe0000-0000-0000-0000-000000000001', 'scored', now(), v.id, 'verified', 8500, 240
  from public.vehicles v where v.name = 'The Civic';

delete from public.vehicles where name = 'The Civic';

select is(
    (select count(*)::int from public.runs where id = 'ababab00-0000-0000-0000-000000000001'),
    1,
    'selling the car does not erase the drives you did in it'
);

select is(
    (select vehicle_id from public.runs where id = 'ababab00-0000-0000-0000-000000000001'),
    null,
    'the run simply forgets which car it was'
);

select * from finish();
rollback;
