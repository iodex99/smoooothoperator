-- pgTAP tests for migration 0013: Today's Challenge assignment cache,
-- candidate search eligibility, and the drive-ready route payload.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

select has_table('public', 'challenge_assignments', 'challenge_assignments table exists');
select ok(
    (select relrowsecurity from pg_class where oid = 'public.challenge_assignments'::regclass),
    'RLS on challenge_assignments'
);
select has_function('public', 'challenge_candidates', 'candidate search function exists');
select has_function('public', 'course_route', 'course_route function exists');

-- ── Fixtures ───────────────────────────────────────────────────────────────
-- driver (in "LA"), buddy (friend), stranger. Courses near LA origin
-- (34.0, -118.5): one public 2km away, one public 30km away, one private
-- (stranger's), one friends-only (buddy's). Plus a public course in
-- "London" (~8750km away) that must never appear in LA searches.

insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', 'a1111111-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'tc-driver@example.com'),
    ('00000000-0000-0000-0000-000000000000', 'a2222222-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'tc-buddy@example.com'),
    ('00000000-0000-0000-0000-000000000000', 'a3333333-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'tc-stranger@example.com');

update public.profiles set username = 'tcdriver' where id = 'a1111111-0000-0000-0000-000000000001';
update public.profiles set username = 'tcbuddy' where id = 'a2222222-0000-0000-0000-000000000002';
update public.profiles set username = 'tcstranger' where id = 'a3333333-0000-0000-0000-000000000003';

insert into public.friendships (requester_id, addressee_id, status)
values ('a1111111-0000-0000-0000-000000000001', 'a2222222-0000-0000-0000-000000000002', 'accepted');

insert into public.courses
    (id, name, creator_id, country, distance_meters, difficulty, turn_count,
     geometry, start_point, finish_point, visibility, status)
values
    ('cccccccc-0000-0000-0000-000000000001', 'TC Near Public', null, 'US', 4300, 3, 12,
     extensions.st_geogfromtext('LINESTRING(-118.52 34.01, -118.50 34.03)'),
     extensions.st_geogfromtext('POINT(-118.52 34.01)'),
     extensions.st_geogfromtext('POINT(-118.50 34.03)'), 'public', 'active'),
    ('cccccccc-0000-0000-0000-000000000002', 'TC Far Public', null, 'US', 6000, 2, 8,
     extensions.st_geogfromtext('LINESTRING(-118.80 34.20, -118.78 34.22)'),
     extensions.st_geogfromtext('POINT(-118.80 34.20)'),
     extensions.st_geogfromtext('POINT(-118.78 34.22)'), 'public', 'active'),
    ('cccccccc-0000-0000-0000-000000000003', 'TC Private', 'a3333333-0000-0000-0000-000000000003', 'US', 5000, 2, 6,
     extensions.st_geogfromtext('LINESTRING(-118.51 34.02, -118.49 34.04)'),
     extensions.st_geogfromtext('POINT(-118.51 34.02)'),
     extensions.st_geogfromtext('POINT(-118.49 34.04)'), 'private', 'active'),
    ('cccccccc-0000-0000-0000-000000000004', 'TC Friends Only', 'a2222222-0000-0000-0000-000000000002', 'US', 5000, 2, 6,
     extensions.st_geogfromtext('LINESTRING(-118.53 34.00, -118.51 34.02)'),
     extensions.st_geogfromtext('POINT(-118.53 34.00)'),
     extensions.st_geogfromtext('POINT(-118.51 34.02)'), 'friends', 'active'),
    ('cccccccc-0000-0000-0000-000000000005', 'TC London', null, 'GB', 7000, 3, 14,
     extensions.st_geogfromtext('LINESTRING(-0.12 51.50, -0.10 51.52)'),
     extensions.st_geogfromtext('POINT(-0.12 51.50)'),
     extensions.st_geogfromtext('POINT(-0.10 51.52)'), 'public', 'active');

insert into public.course_checkpoints (course_id, sequence, center, radius_meters)
values
    ('cccccccc-0000-0000-0000-000000000001', 0, extensions.st_geogfromtext('POINT(-118.52 34.01)'), 40),
    ('cccccccc-0000-0000-0000-000000000001', 1, extensions.st_geogfromtext('POINT(-118.50 34.03)'), 40);

-- ── Candidate eligibility (as the driver, 10 km radius) ───────────────────

select is(
    (select count(*)::int from public.challenge_candidates(
        'a1111111-0000-0000-0000-000000000001', 34.0, -118.5, 10000, now() - interval '1 day')
        where name like 'TC %'),
    2,
    '10 km: near public + friends-only (via friendship) — private and far excluded'
);

select ok(
    not exists (select 1 from public.challenge_candidates(
        'a1111111-0000-0000-0000-000000000001', 34.0, -118.5, 10000, now() - interval '1 day')
        where name = 'TC Private'),
    'a stranger''s private course is never a candidate'
);

select is(
    (select count(*)::int from public.challenge_candidates(
        'a3333333-0000-0000-0000-000000000003', 34.0, -118.5, 10000, now() - interval '1 day')
        where name = 'TC Friends Only'),
    0,
    'friends-only course invisible to non-friends'
);

select is(
    (select count(*)::int from public.challenge_candidates(
        'a1111111-0000-0000-0000-000000000001', 34.0, -118.5, 50000, now() - interval '1 day')
        where name like 'TC %'),
    3,
    '50 km radius also captures the far public course'
);

select ok(
    not exists (select 1 from public.challenge_candidates(
        'a1111111-0000-0000-0000-000000000001', 34.0, -118.5, 100000, now() - interval '1 day')
        where name = 'TC London'),
    'London course never appears in an LA search (100 km)'
);

select ok(
    (select proximity_km from public.challenge_candidates(
        'a1111111-0000-0000-0000-000000000001', 34.0, -118.5, 10000, now() - interval '1 day')
        where name like 'TC %'
        order by proximity_km limit 1) < 3.0,
    'proximity is measured in km from the start gate'
);

-- ── Assignment cache RLS ───────────────────────────────────────────────────

set local role service_role;
insert into public.challenge_assignments (user_id, local_date, format, course_id, radius_km)
values ('a1111111-0000-0000-0000-000000000001', '2026-08-13', 'SMOOTH_SPRINT',
        'cccccccc-0000-0000-0000-000000000001', 10);
reset role;

select set_config('request.jwt.claims',
    '{"sub": "a1111111-0000-0000-0000-000000000001", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.challenge_assignments),
    1,
    'owner sees their own assignment'
);

select throws_ok(
    $$ insert into public.challenge_assignments (user_id, local_date, format, course_id)
       values ('a1111111-0000-0000-0000-000000000001', '2026-08-14', 'SMOOTH_SPRINT',
               'cccccccc-0000-0000-0000-000000000001') $$,
    '42501',
    null,
    'clients can never write their own assignment'
);

select set_config('request.jwt.claims',
    '{"sub": "a2222222-0000-0000-0000-000000000002", "role": "authenticated"}', true);

select is(
    (select count(*)::int from public.challenge_assignments),
    0,
    'other users cannot see the assignment'
);

reset role;

-- ── Drive-ready route payload ──────────────────────────────────────────────

select is(
    jsonb_array_length(public.course_route(
        'a1111111-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000001') -> 'polyline'),
    2,
    'course_route returns the GeoJSON polyline'
);

select is(
    jsonb_array_length(public.course_route(
        'a1111111-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000001') -> 'gates'),
    2,
    'course_route returns ordered gates'
);

select ok(
    public.course_route(
        'a1111111-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000003') is null,
    'course_route refuses courses the user cannot see'
);

select * from finish();
rollback;
