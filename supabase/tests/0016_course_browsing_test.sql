-- Browsing the catalog: the queries behind Explore.
--
-- The point of these tests is that browsing must never become a way to read
-- rows RLS would otherwise hide, and must never be talked into scanning the
-- whole table.

begin;
select plan(14);

-- Fixture zone: mid-Pacific, far from the seeded catalog and from any other
-- test's geography, so counts here are ours alone.
\set zone_lat -14.5
\set zone_lon -150.5

insert into auth.users (id, email)
values ('b1000000-0000-4000-8000-000000000001', 'browse-owner@test.local');

-- Three public courses at increasing distance from the origin, plus a
-- private one that must never appear.
insert into public.courses (
    id, name, city, region, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, visibility, status
)
values
    ('c1000000-0000-4000-8000-000000000001', 'Browse Near', 'Testville', 'Test Region', 'ZZ',
     4300, 3, 20,
     extensions.st_setsrid(extensions.st_makeline(
         extensions.st_makepoint(:zone_lon, :zone_lat),
         extensions.st_makepoint(:zone_lon + 0.01, :zone_lat)), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon, :zone_lat), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.01, :zone_lat), 4326)::extensions.geography,
     'public', 'active'),
    ('c1000000-0000-4000-8000-000000000002', 'Browse Mid', 'Testville', 'Test Region', 'ZZ',
     5000, 2, 14,
     extensions.st_setsrid(extensions.st_makeline(
         extensions.st_makepoint(:zone_lon + 0.05, :zone_lat),
         extensions.st_makepoint(:zone_lon + 0.06, :zone_lat)), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.05, :zone_lat), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.06, :zone_lat), 4326)::extensions.geography,
     'public', 'active'),
    ('c1000000-0000-4000-8000-000000000003', 'Browse Far', 'Otherville', 'Other Region', 'ZZ',
     9000, 5, 44,
     extensions.st_setsrid(extensions.st_makeline(
         extensions.st_makepoint(:zone_lon + 0.9, :zone_lat),
         extensions.st_makepoint(:zone_lon + 0.91, :zone_lat)), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.9, :zone_lat), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.91, :zone_lat), 4326)::extensions.geography,
     'public', 'active'),
    ('c1000000-0000-4000-8000-000000000004', 'Browse Secret', 'Testville', 'Test Region', 'ZZ',
     4000, 3, 10,
     extensions.st_setsrid(extensions.st_makeline(
         extensions.st_makepoint(:zone_lon, :zone_lat + 0.001),
         extensions.st_makepoint(:zone_lon + 0.01, :zone_lat + 0.001)), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon, :zone_lat + 0.001), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.01, :zone_lat + 0.001), 4326)::extensions.geography,
     'private', 'active'),
    ('c1000000-0000-4000-8000-000000000005', 'Browse Archived', 'Testville', 'Test Region', 'ZZ',
     4000, 3, 10,
     extensions.st_setsrid(extensions.st_makeline(
         extensions.st_makepoint(:zone_lon, :zone_lat + 0.002),
         extensions.st_makepoint(:zone_lon + 0.01, :zone_lat + 0.002)), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon, :zone_lat + 0.002), 4326)::extensions.geography,
     extensions.st_setsrid(extensions.st_makepoint(:zone_lon + 0.01, :zone_lat + 0.002), 4326)::extensions.geography,
     'public', 'archived');

-- ── nearby ────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select count(*) from public.courses_near(:zone_lat, :zone_lon, 20000)),
    2::bigint,
    'nearby returns the courses inside the radius and no others'
);

select is(
    (select name from public.courses_near(:zone_lat, :zone_lon, 20000) limit 1),
    'Browse Near',
    'nearest course comes first'
);

select ok(
    (select meters_away from public.courses_near(:zone_lat, :zone_lon, 20000) limit 1) < 1,
    'distance is measured from the driver, not approximated by a box'
);

select ok(
    (select bool_and(name <> 'Browse Secret')
       from public.courses_near(:zone_lat, :zone_lon, 200000)),
    'a private course belonging to someone else never appears in browse'
);

select ok(
    (select bool_and(name <> 'Browse Archived')
       from public.courses_near(:zone_lat, :zone_lon, 200000)),
    'an archived course is not browsable'
);

select is(
    (select count(*) from public.courses_near(:zone_lat, :zone_lon, 200000)),
    3::bigint,
    'a wider radius reaches the far course too'
);

-- Bounded inputs: the function must not be talked into a full-table scan.
select is(
    (select count(*) from public.courses_near(:zone_lat, :zone_lon, 1e12, 100000)),
    (select count(*) from public.courses_near(:zone_lat, :zone_lon, 200000, 100)),
    'an absurd radius and limit are clamped to the maximum, not honoured'
);

select is(
    (select count(*) from public.courses_near(:zone_lat, :zone_lon, 200000, 1)),
    1::bigint,
    'the caller can ask for fewer'
);

select is(
    (select count(*) from public.courses_near(:zone_lat, :zone_lon, 200000, 0)),
    1::bigint,
    'a zero limit is raised to one rather than returning nothing'
);

-- ── by region ─────────────────────────────────────────────────────────────

select is(
    (select count(*) from public.courses_in_region('ZZ')),
    3::bigint,
    'country browse finds every active public course in it'
);

select is(
    (select count(*) from public.courses_in_region('ZZ', 'Test Region')),
    2::bigint,
    'region narrows the country'
);

select is(
    (select count(*) from public.courses_in_region('ZZ', 'Test Region', 'Testville')),
    2::bigint,
    'city narrows it further'
);

select is(
    (select count(*) from public.courses_in_region('zz')),
    3::bigint,
    'country code is case-insensitive — nobody types uppercase'
);

-- ── the region index ──────────────────────────────────────────────────────

select is(
    (select count(*) from public.course_regions() where country = 'ZZ'),
    2::bigint,
    'the region list offers only regions that actually have courses'
);

select * from finish();
rollback;
