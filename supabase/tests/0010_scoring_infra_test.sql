-- pgTAP tests for migration 0010: atomic result application + recovery.
begin;
create extension if not exists pgtap with schema extensions;

select plan(12);

select has_function('public', 'apply_run_result', 'apply_run_result exists');
select has_function('public', 'course_pipeline_geometry', 'geometry RPC exists');
select has_function('public', 'recover_stale_scoring_jobs', 'recovery fn exists');

-- ── Fixtures ──────────────────────────────────────────────────────────────
insert into auth.users (instance_id, id, aud, role, email)
values ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
        'authenticated', 'authenticated', 'driver@example.com');

insert into public.scoring_configs (version, config, active)
values ('1.0.0', '{"test": true}', true)
on conflict (version) do nothing;

insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, benchmark_seconds, visibility, status)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'RPC Course', null, 'US', 1500, 3, 8,
        'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7750 34.0280, -118.7700 34.0300)'::extensions.geography,
        'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
        'SRID=4326;POINT(-118.7700 34.0300)'::extensions.geography,
        95, 'public', 'active');

insert into public.course_checkpoints (course_id, sequence, center, radius_meters)
values
    ('aaaaaaaa-0000-0000-0000-000000000001', 0, 'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography, 40),
    ('aaaaaaaa-0000-0000-0000-000000000001', 1, 'SRID=4326;POINT(-118.7700 34.0300)'::extensions.geography, 40);

insert into public.runs (id, user_id, course_id, status, started_at)
values ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000001', 'uploaded', now());
-- (the enqueue trigger created a pending scoring job)

-- ── Geometry RPC shape ────────────────────────────────────────────────────
select is(
    (select jsonb_array_length(public.course_pipeline_geometry('aaaaaaaa-0000-0000-0000-000000000001') -> 'polyline')),
    3,
    'geometry RPC returns the polyline'
);

select is(
    (select public.course_pipeline_geometry('aaaaaaaa-0000-0000-0000-000000000001') -> 'polyline' -> 0 -> 0),
    to_jsonb(34.0259::double precision),
    'coordinates come back [lat, lon] (pipeline convention)'
);

select is(
    (select jsonb_array_length(public.course_pipeline_geometry('aaaaaaaa-0000-0000-0000-000000000001') -> 'gates')),
    2,
    'geometry RPC returns the gates'
);

-- ── apply_run_result: verified + finished run ─────────────────────────────
select public.apply_run_result(
    'bbbbbbbb-0000-0000-0000-000000000001',
    'verified', 8664, 8625, 9100, 9400, 10000, 97, '1.0.0',
    '[]'::jsonb, 98.5, true,
    '{"points": [[0, 0], [1, 98.5]], "totalSeconds": 98.5}'::jsonb
);

select results_eq(
    $$ select status, verification, score from public.runs
       where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
    $$ values ('scored', 'verified', 8664) $$,
    'authoritative fields land on the run'
);

select is(
    (select score from public.leaderboard_entries
     where user_id = '11111111-1111-1111-1111-111111111111'),
    8664,
    'a verified finished run enters the leaderboard'
);

select is(
    (select count(*)::int from public.ghosts
     where run_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
    1,
    'a ghost is created'
);

select is(
    (select status from public.scoring_jobs
     where run_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
    'done',
    'the scoring job completes'
);

-- A worse later run must NOT displace the best entry.
insert into public.runs (id, user_id, course_id, status, started_at)
values ('bbbbbbbb-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000001', 'uploaded', now());

select public.apply_run_result(
    'bbbbbbbb-0000-0000-0000-000000000002',
    'verified', 8000, 8000, 8000, 8000, 10000, 95, '1.0.0',
    '[]'::jsonb, 110, true, null
);

select is(
    (select score from public.leaderboard_entries
     where user_id = '11111111-1111-1111-1111-111111111111'),
    8664,
    'a worse run never displaces the best entry'
);

-- ── Stale-job recovery ────────────────────────────────────────────────────
insert into public.runs (id, user_id, course_id, status, started_at)
values ('bbbbbbbb-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000001', 'uploaded', now());

-- Backdate requires bypassing the updated_at trigger (test-only, superuser).
alter table public.scoring_jobs disable trigger scoring_jobs_set_updated_at;
update public.scoring_jobs
set status = 'processing',
    updated_at = now() - interval '10 minutes'
where run_id = 'bbbbbbbb-0000-0000-0000-000000000003';
alter table public.scoring_jobs enable trigger scoring_jobs_set_updated_at;

select is(
    public.recover_stale_scoring_jobs(),
    1,
    'stale processing jobs return to pending'
);

select * from finish();
rollback;
