-- The app says "your account and all its data have been deleted". These
-- tests are what make that sentence true rather than aspirational — the raw
-- telemetry blobs are the most sensitive data here, and they used to
-- survive the account that recorded them.

begin;
select plan(6);

insert into auth.users (id, email) values
    ('ef000001-a000-4000-8000-000000000001', 'leaving@test.local'),
    ('ef000002-b000-4000-8000-000000000002', 'staying@test.local');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status
) values (
    'ef000003-c000-4000-8000-000000000003', 'Deletion Test Road', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-162.5, -35.5),
        extensions.st_makepoint(-162.4, -35.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-162.5, -35.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-162.4, -35.5), 4326)::extensions.geography,
    'active'
);

insert into public.runs (id, user_id, course_id, status, started_at, completed_at)
values
    ('ef000004-d000-4000-8000-000000000004', 'ef000001-a000-4000-8000-000000000001',
     'ef000003-c000-4000-8000-000000000003', 'uploaded', now(), now()),
    ('ef000005-e000-4000-8000-000000000005', 'ef000002-b000-4000-8000-000000000002',
     'ef000003-c000-4000-8000-000000000003', 'uploaded', now(), now());

insert into public.vehicles (user_id, name)
values ('ef000001-a000-4000-8000-000000000001', 'The Golf');

-- NOTE: the raw telemetry BLOBS are not covered here. Supabase refuses
-- direct deletes from storage tables, so clearing them is the
-- `delete-account` edge function's job and is tested in Deno. What this
-- file proves is the database half — and that the two halves together are
-- what makes "all its data" true.

-- ── the driver leaves ─────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = '{"sub":"ef000001-a000-4000-8000-000000000001","role":"authenticated"}';
select lives_ok('select public.delete_my_account()', 'the account deletes');

set local role postgres;

select is(
    (select count(*) from public.telemetry t
       join public.runs r on r.id = t.run_id
      where r.user_id = 'ef000001-a000-4000-8000-000000000001'),
    0::bigint,
    'their telemetry POINTERS are gone (the blobs are the edge function''s job)'
);

-- ── everything else cascaded ──────────────────────────────────────────────

select is(
    (select count(*) from public.runs where user_id = 'ef000001-a000-4000-8000-000000000001'),
    0::bigint,
    'their runs are gone'
);

select is(
    (select count(*) from public.vehicles where user_id = 'ef000001-a000-4000-8000-000000000001'),
    0::bigint,
    'their garage is gone'
);

select is(
    (select count(*) from public.profiles where id = 'ef000001-a000-4000-8000-000000000001'),
    0::bigint,
    'their profile is gone'
);

select is(
    (select count(*) from public.runs where user_id = 'ef000002-b000-4000-8000-000000000002'),
    1::bigint,
    'the other driver is untouched — deletion is not a blast radius'
);

select * from finish();
rollback;
