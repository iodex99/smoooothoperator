-- pgTAP tests for migration 0005: runs / telemetry / scoring_jobs trust boundary.
begin;
create extension if not exists pgtap with schema extensions;

select plan(19);

-- ── Schema ────────────────────────────────────────────────────────────────
select has_table('public', 'runs', 'runs table exists');
select has_table('public', 'telemetry', 'telemetry envelope table exists');
select has_table('public', 'scoring_jobs', 'scoring_jobs table exists');

select ok((select relrowsecurity from pg_class where oid = 'public.runs'::regclass), 'RLS on runs');
select ok((select relrowsecurity from pg_class where oid = 'public.telemetry'::regclass), 'RLS on telemetry');
select ok((select relrowsecurity from pg_class where oid = 'public.scoring_jobs'::regclass), 'RLS on scoring_jobs');

-- ── Fixtures ──────────────────────────────────────────────────────────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
     'authenticated', 'authenticated', 'driver1@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
     'authenticated', 'authenticated', 'driver2@example.com');

insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, visibility, status)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'Golden Course', null, 'US', 1500, 3, 8,
        'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7700 34.0300)'::extensions.geography,
        'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
        'SRID=4326;POINT(-118.7700 34.0300)'::extensions.geography,
        'public', 'active');

-- ── Owner path ────────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

insert into public.runs (id, user_id, course_id, status, started_at, client_score)
values ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000001', 'recording', now(), 8500);

select is(
    (select count(*)::int from public.runs),
    1,
    'owner can create and read their own run'
);

select throws_ok(
    $$ insert into public.runs (user_id, course_id, status, started_at)
       values ('22222222-2222-2222-2222-222222222222',
               'aaaaaaaa-0000-0000-0000-000000000001', 'recording', now()) $$,
    '42501',
    null,
    'cannot create a run for someone else'
);

select throws_ok(
    $$ update public.runs set score = 9999
       where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
    '42501',
    null,
    'clients can NEVER write the authoritative score (spec §45)'
);

select throws_ok(
    $$ update public.runs set verification = 'verified'
       where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
    '42501',
    null,
    'clients can never verify their own runs'
);

-- Lifecycle transition the client IS allowed to make:
update public.runs
set status = 'uploaded', completed_at = now(), duration_seconds = 120, distance_meters = 1500
where id = 'bbbbbbbb-0000-0000-0000-000000000001';

select is(
    (select status from public.runs where id = 'bbbbbbbb-0000-0000-0000-000000000001'),
    'uploaded',
    'owner can mark their run uploaded'
);

-- Telemetry envelope
insert into public.telemetry (run_id, storage_path, gps_count, imu_count, byte_size, sha256)
values ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111/run1.ndjson.gz',
        519, 2595, 262144, repeat('ab', 32));

select is(
    (select count(*)::int from public.telemetry),
    1,
    'owner can register and read their telemetry envelope'
);

select throws_ok(
    $$ select count(*) from public.scoring_jobs $$,
    '42501',
    null,
    'the scoring queue is invisible to clients'
);

reset role;

-- ── Enqueue trigger (inspected as superuser) ──────────────────────────────
select is(
    (select count(*)::int from public.scoring_jobs
     where run_id = 'bbbbbbbb-0000-0000-0000-000000000001' and status = 'pending'),
    1,
    'transition to uploaded enqueued exactly one scoring job'
);

-- Re-marking uploaded must not duplicate the job.
update public.runs set status = 'processing' where id = 'bbbbbbbb-0000-0000-0000-000000000001';
update public.runs set status = 'uploaded' where id = 'bbbbbbbb-0000-0000-0000-000000000001';

select is(
    (select count(*)::int from public.scoring_jobs
     where run_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
    1,
    're-upload transitions never duplicate queue rows'
);

-- ── Stranger path ─────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.runs),
    0,
    'strangers see no one else''s runs'
);

select is(
    (select count(*)::int from public.telemetry),
    0,
    'strangers see no one else''s telemetry envelopes (spec §66)'
);

reset role;

-- ── Anonymous path ────────────────────────────────────────────────────────
select set_config('request.jwt.claims', '{"role": "anon"}', true);
set local role anon;

select throws_ok(
    $$ select count(*) from public.runs $$,
    '42501',
    null,
    'anon has no access to runs at all'
);

select throws_ok(
    $$ insert into public.runs (user_id, course_id, status, started_at)
       values ('11111111-1111-1111-1111-111111111111',
               'aaaaaaaa-0000-0000-0000-000000000001', 'recording', now()) $$,
    '42501',
    null,
    'anon cannot insert runs'
);

reset role;

select * from finish();
rollback;
