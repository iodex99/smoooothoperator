-- A course without a benchmark scores every run on it at ZERO pace — 35% of
-- the score, gone silently. `validate-course` never set one, so every
-- user-created course had this, and custom courses are a paid feature.

begin;
select plan(10);

insert into auth.users (id, email)
values ('9b000001-a000-4000-8000-000000000001', 'benchmark@test.local');

-- ── the invalid state is now unrepresentable ──────────────────────────────

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, creator_id
) values (
    '9b000002-b000-4000-8000-000000000002', 'Derived Benchmark Course', 'ZZ',
    5000, 3, 20,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-155.5, -25.5),
        extensions.st_makepoint(-155.4, -25.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-155.5, -25.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-155.4, -25.5), 4326)::extensions.geography,
    'active', '9b000001-a000-4000-8000-000000000001'
);

select isnt(
    (select benchmark_seconds from public.courses
      where id = '9b000002-b000-4000-8000-000000000002'),
    null,
    'a course inserted without a benchmark is given one'
);

select ok(
    (select benchmark_seconds from public.courses
      where id = '9b000002-b000-4000-8000-000000000002') > 0,
    'and it is a usable number, not zero'
);

-- ── the derived number is sane ────────────────────────────────────────────

select ok(
    (select distance_meters / benchmark_seconds * 3.6 from public.courses
      where id = '9b000002-b000-4000-8000-000000000002') between 45 and 88,
    'the implied speed sits inside the curated catalog''s own 45-88 km/h range'
);

select ok(
    public.derive_benchmark_seconds(5000, 60) > public.derive_benchmark_seconds(5000, 5),
    'a twistier road gets a slower reference — corners take time'
);

select ok(
    public.derive_benchmark_seconds(10000, 20) > public.derive_benchmark_seconds(5000, 10),
    'a longer road at the same turn density takes longer'
);

-- ── degenerate inputs do not produce a nonsense reference ─────────────────

select ok(
    public.derive_benchmark_seconds(0, 0) >= 1,
    'a zero-length course still yields a positive benchmark rather than zero'
);

select ok(
    public.derive_benchmark_seconds(1000, 100000) >= 1,
    'an absurd turn count is clamped, not allowed to divide by ~nothing'
);

select ok(
    (select distance_meters / benchmark_seconds * 3.6
       from (select 1000.0 as distance_meters,
                    public.derive_benchmark_seconds(1000, 100000) as benchmark_seconds) x
    ) >= 45,
    'the reference speed floor holds even for a hairpin-dense course'
);

-- ── an explicit benchmark is respected ────────────────────────────────────

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, benchmark_seconds
) values (
    '9b000003-c000-4000-8000-000000000003', 'Curated Benchmark Course', 'ZZ',
    5000, 3, 20,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-155.3, -25.5),
        extensions.st_makepoint(-155.2, -25.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-155.3, -25.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-155.2, -25.5), 4326)::extensions.geography,
    'active', 240
);

select is(
    (select benchmark_seconds from public.courses
      where id = '9b000003-c000-4000-8000-000000000003'),
    240,
    'a curated benchmark is never overwritten by the derivation'
);

-- ── nothing in the catalog is left without one ────────────────────────────

select is(
    (select count(*) from public.courses where benchmark_seconds is null),
    0::bigint,
    'no course anywhere is left scoring zero pace'
);

select * from finish();
rollback;
