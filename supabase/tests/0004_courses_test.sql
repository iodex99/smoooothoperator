-- pgTAP tests for migration 0004: courses + course_checkpoints visibility matrix.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

-- ── Schema ────────────────────────────────────────────────────────────────
select has_table('public', 'courses', 'courses table exists');
select has_table('public', 'course_checkpoints', 'course_checkpoints table exists');

select ok(
    (select relrowsecurity from pg_class where oid = 'public.courses'::regclass),
    'RLS enabled on courses'
);
select ok(
    (select relrowsecurity from pg_class where oid = 'public.course_checkpoints'::regclass),
    'RLS enabled on course_checkpoints'
);

-- ── Fixtures ──────────────────────────────────────────────────────────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
     'authenticated', 'authenticated', 'creator@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
     'authenticated', 'authenticated', 'stranger@example.com');

insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, benchmark_seconds, visibility, status)
values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Malibu Demo', null, 'US', 20600, 4, 23,
     'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7050 34.0480)'::extensions.geography,
     'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
     'SRID=4326;POINT(-118.7050 34.0480)'::extensions.geography,
     1121, 'public', 'active'),
    ('aaaaaaaa-0000-0000-0000-000000000002', 'Secret Practice Loop',
     '11111111-1111-1111-1111-111111111111', 'US', 8000, 2, 9,
     'SRID=4326;LINESTRING(-118.50 34.10, -118.48 34.11)'::extensions.geography,
     'SRID=4326;POINT(-118.50 34.10)'::extensions.geography,
     'SRID=4326;POINT(-118.48 34.11)'::extensions.geography,
     null, 'private', 'active'),
    ('aaaaaaaa-0000-0000-0000-000000000003', 'Unfinished Draft',
     '11111111-1111-1111-1111-111111111111', 'US', 5000, 1, 4,
     'SRID=4326;LINESTRING(-118.40 34.20, -118.39 34.21)'::extensions.geography,
     'SRID=4326;POINT(-118.40 34.20)'::extensions.geography,
     'SRID=4326;POINT(-118.39 34.21)'::extensions.geography,
     null, 'public', 'draft');

insert into public.course_checkpoints (course_id, sequence, center, radius_meters)
values
    ('aaaaaaaa-0000-0000-0000-000000000001', 0, 'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography, 30),
    ('aaaaaaaa-0000-0000-0000-000000000001', 1, 'SRID=4326;POINT(-118.7400 34.0350)'::extensions.geography, 40),
    ('aaaaaaaa-0000-0000-0000-000000000001', 2, 'SRID=4326;POINT(-118.7050 34.0480)'::extensions.geography, 30),
    ('aaaaaaaa-0000-0000-0000-000000000002', 0, 'SRID=4326;POINT(-118.50 34.10)'::extensions.geography, 30);

-- ── Constraints ───────────────────────────────────────────────────────────
select throws_ok(
    $$ insert into public.courses (name, distance_meters, difficulty, geometry, start_point, finish_point)
       values ('Bad Difficulty', 1000, 9,
               'SRID=4326;LINESTRING(0 0, 1 1)'::extensions.geography,
               'SRID=4326;POINT(0 0)'::extensions.geography,
               'SRID=4326;POINT(1 1)'::extensions.geography) $$,
    '23514',
    null,
    'difficulty outside 1-5 is rejected'
);

select throws_ok(
    $$ insert into public.course_checkpoints (course_id, sequence, center, radius_meters)
       values ('aaaaaaaa-0000-0000-0000-000000000001', 9,
               'SRID=4326;POINT(0 0)'::extensions.geography, 2000) $$,
    '23514',
    null,
    'checkpoint radius outside 5-500m is rejected'
);

select throws_ok(
    $$ insert into public.course_checkpoints (course_id, sequence, center, radius_meters)
       values ('aaaaaaaa-0000-0000-0000-000000000001', 0,
               'SRID=4326;POINT(0 0)'::extensions.geography, 30) $$,
    '23505',
    null,
    'duplicate checkpoint sequence per course is rejected'
);

-- ── RLS: anonymous ────────────────────────────────────────────────────────
select set_config('request.jwt.claims', '{"role": "anon"}', true);
set local role anon;

select results_eq(
    $$ select id::text from public.courses where id::text like 'aaaaaaaa-%' order by id $$,
    array['aaaaaaaa-0000-0000-0000-000000000001'],
    'anon sees only active public courses (no private, no drafts)'
);

select is(
    (select count(*)::int from public.course_checkpoints where course_id::text like 'aaaaaaaa-%'),
    3,
    'anon sees only checkpoints of visible courses'
);

select throws_ok(
    $$ insert into public.courses (name, distance_meters, geometry, start_point, finish_point)
       values ('Anon Course', 1000,
               'SRID=4326;LINESTRING(0 0, 1 1)'::extensions.geography,
               'SRID=4326;POINT(0 0)'::extensions.geography,
               'SRID=4326;POINT(1 1)'::extensions.geography) $$,
    '42501',
    null,
    'anon cannot insert courses'
);

reset role;

-- ── RLS: the creator ──────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.courses where id::text like 'aaaaaaaa-%'),
    3,
    'creator sees public courses plus their own private and draft courses'
);

select is(
    (select count(*)::int from public.course_checkpoints where course_id::text like 'aaaaaaaa-%'),
    4,
    'creator sees checkpoints of their own private course too'
);

select throws_ok(
    $$ insert into public.courses (name, creator_id, distance_meters, geometry, start_point, finish_point)
       values ('Direct Insert', '11111111-1111-1111-1111-111111111111', 1000,
               'SRID=4326;LINESTRING(0 0, 1 1)'::extensions.geography,
               'SRID=4326;POINT(0 0)'::extensions.geography,
               'SRID=4326;POINT(1 1)'::extensions.geography) $$,
    '42501',
    null,
    'even authenticated users cannot insert courses directly (validated edge fn path only)'
);

reset role;

-- ── RLS: a stranger ───────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

select results_eq(
    $$ select id::text from public.courses where id::text like 'aaaaaaaa-%' order by id $$,
    array['aaaaaaaa-0000-0000-0000-000000000001'],
    'strangers see only active public courses'
);

select is(
    (select count(*)::int from public.course_checkpoints
     where course_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
    0,
    'private course checkpoints are invisible to strangers'
);

reset role;

-- ── Cascade ───────────────────────────────────────────────────────────────
delete from public.courses where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select is(
    (select count(*)::int from public.course_checkpoints
     where course_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    0,
    'deleting a course cascades to its checkpoints'
);

select * from finish();
rollback;
