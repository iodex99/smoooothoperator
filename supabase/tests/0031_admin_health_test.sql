-- A health panel that reads zero because it is broken looks exactly like a
-- health panel that reads zero because everything is fine. So these tests
-- create each kind of trouble and require it to be reported, rather than
-- checking the function runs.

begin;
select plan(8);

insert into auth.users (id, email) values
    ('fa000001-0000-4000-8000-000000000001', 'operator@test.local'),
    ('fa000002-0000-4000-8000-000000000002', 'driver@test.local');

insert into public.admins (user_id) values ('fa000001-0000-4000-8000-000000000001');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status
) values (
    'fa000010-0000-4000-8000-000000000010', 'Health Road', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-178.5, -62.5),
        extensions.st_makepoint(-178.4, -62.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-178.5, -62.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-178.4, -62.5), 4326)::extensions.geography,
    'active'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"fa000001-0000-4000-8000-000000000001","role":"authenticated"}';

-- ── quiet by default ──────────────────────────────────────────────────────

select is(
    (select failed_scoring_jobs from public.admin_health()),
    0::bigint,
    'a healthy database reports nothing wrong'
);

set local role postgres;

-- ── 1. a run that will never be scored ────────────────────────────────────

insert into public.runs (id, user_id, course_id, status, started_at, completed_at)
values ('fa000020-0000-4000-8000-000000000020', 'fa000002-0000-4000-8000-000000000002',
        'fa000010-0000-4000-8000-000000000010', 'uploaded',
        now() - interval '30 hours', now() - interval '30 hours');

-- The enqueue trigger has already made a job for it; drive it to failure the
-- way the scorer would.
--
-- `set_updated_at` re-stamps the row on every UPDATE, so a fixture cannot
-- age one while it is armed — the timestamp this test is about would be
-- silently replaced with now() and the assertion would fail for a reason
-- that has nothing to do with the health function.
alter table public.scoring_jobs disable trigger scoring_jobs_set_updated_at;

update public.scoring_jobs
   set status = 'failed', attempts = 5, last_error = 'telemetry hash mismatch',
       updated_at = now() - interval '26 hours'
 where run_id = 'fa000020-0000-4000-8000-000000000020';

alter table public.scoring_jobs enable trigger scoring_jobs_set_updated_at;

set local role authenticated;
set local request.jwt.claims = '{"sub":"fa000001-0000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select failed_scoring_jobs from public.admin_health()),
    1::bigint,
    'a scoring job that gave up is reported — the driver is never told, so '
    'somebody has to be'
);

select ok(
    (select oldest_failed_job_hours from public.admin_health()) >= 24,
    'with the age of the oldest, because a count cannot tell "this morning" '
    'from "since March"'
);

select is(
    (select last_error from public.admin_health()),
    'telemetry hash mismatch',
    'and the most recent error in its own words — a count says something is '
    'broken, this tends to say what'
);

select is(
    (select unscored_runs from public.admin_health()),
    1::bigint,
    'the run itself shows up as never scored'
);

-- ── 2. nothing is driving the queue ───────────────────────────────────────

set local role postgres;
insert into public.runs (id, user_id, course_id, status, started_at, completed_at)
values ('fa000021-0000-4000-8000-000000000021', 'fa000002-0000-4000-8000-000000000002',
        'fa000010-0000-4000-8000-000000000010', 'uploaded', now(), now());
update public.scoring_jobs
   set status = 'pending', next_attempt_at = now() - interval '3 hours'
 where run_id = 'fa000021-0000-4000-8000-000000000021';

set local role authenticated;
set local request.jwt.claims = '{"sub":"fa000001-0000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select overdue_scoring_jobs from public.admin_health()),
    1::bigint,
    'a job past its own retry time means the sweeper is not running — a '
    'config problem that otherwise produces no error anywhere, because the '
    'sweeper returns 0 rather than failing when unconfigured'
);

-- ── 3. money in, nobody entitled ──────────────────────────────────────────

set local role postgres;
insert into public.subscriptions
    (original_transaction_id, latest_transaction_id, user_id, product_id,
     status, expires_at, environment, created_at)
values ('txn-orphan', 'txn-orphan', null, 'smooooth.pro.monthly',
        'active', now() + interval '20 days', 'production', now() - interval '3 days');

set local role authenticated;
set local request.jwt.claims = '{"sub":"fa000001-0000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select unattributed_subscriptions from public.admin_health()),
    1::bigint,
    'a subscription attached to no account is revenue collected for a '
    'product nobody received'
);

-- ── and it is operator-only, like everything else here ────────────────────

set local request.jwt.claims = '{"sub":"fa000002-0000-4000-8000-000000000002","role":"authenticated"}';

select throws_ok(
    'select * from public.admin_health()',
    null,
    null,
    'a driver cannot read the health of the business'
);

select * from finish();
rollback;
