-- Browsing the catalog is the app's hottest path — Explore opens on it
-- every session. It was O(catalog size) and nobody would have noticed until
-- the product succeeded.
--
-- These are correctness tests for the performance work. The measurements
-- live in the migration; what is asserted here is that the fixes are
-- actually in place and that making browse fast did not make it leak.

begin;
select plan(11);

insert into auth.users (id, email) values
    ('cb000001-a000-4000-8000-000000000001', 'browser@test.local'),
    ('cb000002-b000-4000-8000-000000000002', 'creator@test.local');

-- ── the indexes that make it scale ────────────────────────────────────────

select ok(
    exists (select 1 from pg_indexes
             where tablename = 'courses' and indexdef like '%gist%start_point%'),
    'start_point is spatially indexed — the query filters on it, and the '
    'only GiST index was on the LineString'
);

select ok(
    exists (select 1 from pg_indexes
             where tablename = 'courses' and indexname = 'courses_popular_idx'
               and indexdef like '%name%'),
    'the popularity index includes the tie-break column, or the scan reads '
    'every matching row to sort within equal counts'
);

-- ── the denormalised count stays true ─────────────────────────────────────

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, visibility
) values (
    'cb000003-c000-4000-8000-000000000003', 'Counted Course', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-165.5, -40.5),
        extensions.st_makepoint(-165.4, -40.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-165.5, -40.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-165.4, -40.5), 4326)::extensions.geography,
    'active', 'public'
);

select is(
    (select driver_count from public.courses where id = 'cb000003-c000-4000-8000-000000000003'),
    0,
    'a new course starts at zero drivers'
);

insert into public.runs (id, user_id, course_id, status, verification, score, started_at, completed_at)
values ('cb000004-d000-4000-8000-000000000004', 'cb000001-a000-4000-8000-000000000001',
        'cb000003-c000-4000-8000-000000000003', 'scored', 'verified', 8000, now(), now());

insert into public.leaderboard_entries (user_id, course_id, run_id, score, duration_seconds)
values ('cb000001-a000-4000-8000-000000000001', 'cb000003-c000-4000-8000-000000000003',
        'cb000004-d000-4000-8000-000000000004', 8000, 190);

select is(
    (select driver_count from public.courses where id = 'cb000003-c000-4000-8000-000000000003'),
    1,
    'the count follows a new leaderboard entry — a stale count is shown to '
    'drivers as "how many people have driven this"'
);

delete from public.leaderboard_entries
 where course_id = 'cb000003-c000-4000-8000-000000000003';

select is(
    (select driver_count from public.courses where id = 'cb000003-c000-4000-8000-000000000003'),
    0,
    'and follows a removal back down'
);

-- ── making it fast must not have made it leak ─────────────────────────────
--
-- The browse functions are now SECURITY DEFINER, which bypasses RLS: the
-- spatial index is unusable underneath a row-security barrier because the
-- PostGIS predicates are not LEAKPROOF. The visibility rules are applied
-- inside instead, so these assertions are the ones that matter most.

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, visibility, creator_id
) values (
    'cb000005-e000-4000-8000-000000000005', 'Someone Elses Private Road', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-165.5, -40.501),
        extensions.st_makepoint(-165.4, -40.501)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-165.5, -40.501), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-165.4, -40.501), 4326)::extensions.geography,
    'active', 'private', 'cb000002-b000-4000-8000-000000000002'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"cb000001-a000-4000-8000-000000000001","role":"authenticated"}';

select ok(
    (select bool_and(name <> 'Someone Elses Private Road')
       from public.courses_near(-40.5, -165.5, 50000)),
    'a private course belonging to someone else is still invisible nearby'
);

select ok(
    (select bool_and(name <> 'Someone Elses Private Road')
       from public.courses_in_region('ZZ')),
    'and still invisible by region'
);

select ok(
    (select bool_or(name = 'Counted Course')
       from public.courses_near(-40.5, -165.5, 50000)),
    'while a public course is found'
);

-- The creator still sees their own.
set local request.jwt.claims = '{"sub":"cb000002-b000-4000-8000-000000000002","role":"authenticated"}';

select ok(
    (select bool_or(name = 'Someone Elses Private Road')
       from public.courses_near(-40.5, -165.5, 50000)),
    'the creator still sees their own private course'
);

-- ── the vicinity is bounded ───────────────────────────────────────────────

select ok(
    (select count(*) from public.courses_near(-40.5, -165.5, 1e12, 100000)) <= 100,
    'an absurd radius and limit are still clamped'
);

select ok(
    (select count(*) from public.courses_near(0, 0, 100)) = 0,
    'the middle of the Atlantic returns nothing rather than everything'
);

select * from finish();
rollback;
