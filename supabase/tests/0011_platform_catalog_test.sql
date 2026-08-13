-- pgTAP tests for the seeded platform course catalog (docs/COURSES.md).
-- Guards the generated seed's integrity, not individual courses: every
-- platform course must be complete, gated, benchmarked, and inside the
-- editorial limits — a regeneration that breaks the rules fails CI.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

-- Catalog size floor (raise deliberately as the catalog grows).
select cmp_ok(
    (select count(*)::int from public.courses where creator_id is null),
    '>=', 80,
    'the platform catalog is seeded'
);

select is(
    (select count(*)::int from public.courses
     where creator_id is null and (visibility <> 'public' or status <> 'active')),
    0,
    'every platform course is public and active'
);

select is(
    (select count(*)::int from public.courses c
     where c.creator_id is null
       and (select count(*) from public.course_checkpoints cc
            where cc.course_id = c.id) <> 5),
    0,
    'every platform course has exactly 5 gates (0/25/50/75/100%)'
);

select is(
    (select count(*)::int from public.courses
     where creator_id is null
       and (benchmark_seconds is null or benchmark_seconds <= 0)),
    0,
    'every platform course carries a reference benchmark (spec §57)'
);

select is(
    (select count(*)::int from public.courses
     where creator_id is null
       and (distance_meters < 3000 or distance_meters > 80000)),
    0,
    'course lengths stay inside editorial limits'
);

select is(
    (select count(*)::int from public.courses
     where creator_id is null and (difficulty < 1 or difficulty > 5)),
    0,
    'difficulty stays in 1-5'
);

select is(
    (select count(*)::int from public.courses
     where creator_id is null and country !~ '^[A-Z]{2}$'),
    0,
    'every platform course has an ISO2 country'
);

-- The user's home market and the flagship market are both represented.
select ok(
    (select count(*) from public.courses where creator_id is null and country = 'IN') >= 20
    and (select count(*) from public.courses where creator_id is null and country = 'US') >= 15,
    'India and US both have real catalog depth'
);

select * from finish();
rollback;
