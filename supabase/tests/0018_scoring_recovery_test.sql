-- Stale scoring jobs: the sweeper used to reset them forever and never
-- re-invoke the scorer, so a crashed job meant a run that was never scored
-- authoritatively. These tests are about the two ways that goes wrong:
-- a job that is never retried, and a job that is retried forever.

begin;
select plan(9);

insert into auth.users (id, email)
values ('5c000001-a000-4000-8000-000000000001', 'sweeper@test.local');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status
) values (
    '5c000002-b000-4000-8000-000000000002', 'Sweeper Course', 'ZZ', 4000, 3, 10,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-151.5, -15.5),
        extensions.st_makepoint(-151.4, -15.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-151.5, -15.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-151.4, -15.5), 4326)::extensions.geography,
    'active'
);

insert into public.runs (id, user_id, course_id, status, started_at, completed_at)
values
    ('5c000003-c000-4000-8000-000000000003', '5c000001-a000-4000-8000-000000000001',
     '5c000002-b000-4000-8000-000000000002', 'uploaded', now() - interval '1 hour', now()),
    ('5c000004-d000-4000-8000-000000000004', '5c000001-a000-4000-8000-000000000001',
     '5c000002-b000-4000-8000-000000000002', 'uploaded', now() - interval '2 hour', now());

-- Inserting a run enqueues its job; drive both into the state this test is
-- about — stuck in 'processing' with a worker that never came back.
--
-- The updated_at trigger has to come off first: it re-stamps every UPDATE
-- with now(), so a fixture cannot age a row while it is armed, and the
-- sweeper (which keys on updated_at) would see nothing stale.
alter table public.scoring_jobs disable trigger scoring_jobs_set_updated_at;
update public.scoring_jobs
   set status = 'processing', attempts = 0, updated_at = now() - interval '10 minutes'
 where run_id = '5c000003-c000-4000-8000-000000000003';

update public.scoring_jobs
   set status = 'processing', attempts = 5, updated_at = now() - interval '10 minutes'
 where run_id = '5c000004-d000-4000-8000-000000000004';

alter table public.scoring_jobs enable trigger scoring_jobs_set_updated_at;

-- ── the sweep ─────────────────────────────────────────────────────────────

select lives_ok(
    'select public.recover_stale_scoring_jobs()',
    'the sweeper runs'
);

select is(
    (select status from public.scoring_jobs
      where run_id = '5c000003-c000-4000-8000-000000000003'),
    'pending',
    'a crashed job goes back to pending'
);

select is(
    (select attempts from public.scoring_jobs
      where run_id = '5c000003-c000-4000-8000-000000000003'),
    1,
    'the attempt is COUNTED — it never was, so a poisoned job retried forever'
);

select ok(
    (select next_attempt_at from public.scoring_jobs
      where run_id = '5c000003-c000-4000-8000-000000000003') > now(),
    'the retry is backed off rather than spinning immediately'
);

select is(
    (select status from public.scoring_jobs
      where run_id = '5c000004-d000-4000-8000-000000000004'),
    'failed',
    'a job that used up its attempts stops instead of cycling silently'
);

select ok(
    (select last_error from public.scoring_jobs
      where run_id = '5c000004-d000-4000-8000-000000000004') is not null,
    'and it records WHY, so it can be looked at rather than lost'
);

-- ── a healthy job is left alone ───────────────────────────────────────────

update public.scoring_jobs
   set status = 'processing', attempts = 0, updated_at = now()
 where run_id = '5c000003-c000-4000-8000-000000000003';

select public.recover_stale_scoring_jobs();


select is(
    (select status from public.scoring_jobs
      where run_id = '5c000003-c000-4000-8000-000000000003'),
    'processing',
    'a job that is merely slow is not stolen from its worker'
);

-- ── the queue is server machinery ─────────────────────────────────────────

select ok(
    not has_function_privilege('authenticated',
        'public.recover_stale_scoring_jobs(integer, interval)', 'execute'),
    'clients cannot drive the scoring queue'
);

select ok(
    not has_function_privilege('authenticated',
        'public.drive_pending_scoring_jobs(integer)', 'execute'),
    'clients cannot ask the server to rescore at will'
);

select * from finish();
rollback;
