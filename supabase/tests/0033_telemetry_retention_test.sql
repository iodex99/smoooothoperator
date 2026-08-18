-- Retention decides, ninety days after the fact, that somebody's raw
-- location trace can be destroyed. Every rule about which blobs are due is
-- therefore asserted here by CREATING the case, not by reading the query:
-- a retention job that purges one run too many has destroyed evidence a
-- driver may need, and one that purges none quietly grows the bill forever.

begin;
select plan(14);

insert into auth.users (id, email) values
    ('d0000001-0000-4000-8000-000000000001', 'driver@test.local');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, visibility
)
select id, nm, 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-176.9, -61.5),
        extensions.st_makepoint(-176.8, -61.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-176.9, -61.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-176.8, -61.5), 4326)::extensions.geography,
    'active', 'public'
from (values
    ('d0000010-0000-4000-8000-000000000010'::uuid, 'Retention Road')
) t(id, nm);

-- Five runs, differing only in the two things the policy looks at: how old
-- they are, and whether they finished.
insert into public.runs (id, user_id, course_id, status, started_at, completed_at)
values
    -- old and scored: due
    ('d0000020-0000-4000-8000-000000000020', 'd0000001-0000-4000-8000-000000000001',
     'd0000010-0000-4000-8000-000000000010', 'scored',
     now() - interval '200 days', now() - interval '200 days'),
    -- old and scored, a little past the window: due
    ('d0000021-0000-4000-8000-000000000021', 'd0000001-0000-4000-8000-000000000001',
     'd0000010-0000-4000-8000-000000000010', 'scored',
     now() - interval '91 days', now() - interval '91 days'),
    -- inside the window: not due
    ('d0000022-0000-4000-8000-000000000022', 'd0000001-0000-4000-8000-000000000001',
     'd0000010-0000-4000-8000-000000000010', 'scored',
     now() - interval '89 days', now() - interval '89 days'),
    -- old but never scored: NOT due, the blob is the only copy of the drive
    ('d0000023-0000-4000-8000-000000000023', 'd0000001-0000-4000-8000-000000000001',
     'd0000010-0000-4000-8000-000000000010', 'uploaded',
     now() - interval '300 days', null),
    -- old and failed: NOT due, it may yet be re-driven
    ('d0000024-0000-4000-8000-000000000024', 'd0000001-0000-4000-8000-000000000001',
     'd0000010-0000-4000-8000-000000000010', 'failed',
     now() - interval '300 days', now() - interval '300 days');

insert into public.telemetry (id, run_id, storage_path, gps_count, imu_count, byte_size, sha256)
values
    ('d0000030-0000-4000-8000-000000000030', 'd0000020-0000-4000-8000-000000000020',
     'd0000001-0000-4000-8000-000000000001/aaa.json.gz', 100, 500, 1000,
     repeat('a', 64)),
    ('d0000031-0000-4000-8000-000000000031', 'd0000021-0000-4000-8000-000000000021',
     'd0000001-0000-4000-8000-000000000001/bbb.json.gz', 100, 500, 1000,
     repeat('b', 64)),
    ('d0000032-0000-4000-8000-000000000032', 'd0000022-0000-4000-8000-000000000022',
     'd0000001-0000-4000-8000-000000000001/ccc.json.gz', 100, 500, 1000,
     repeat('c', 64)),
    ('d0000033-0000-4000-8000-000000000033', 'd0000023-0000-4000-8000-000000000023',
     'd0000001-0000-4000-8000-000000000001/ddd.json.gz', 100, 500, 1000,
     repeat('d', 64)),
    ('d0000034-0000-4000-8000-000000000034', 'd0000024-0000-4000-8000-000000000024',
     'd0000001-0000-4000-8000-000000000001/eee.json.gz', 100, 500, 1000,
     repeat('e', 64));

-- ── what is due, and what is deliberately not ────────────────────────────

select is(
    (select count(*) from public.telemetry_due_for_purge(100)
      where telemetry_id in ('d0000030-0000-4000-8000-000000000030',
                             'd0000031-0000-4000-8000-000000000031')),
    2::bigint,
    'a scored run past the window is due for purge'
);

select is(
    (select count(*) from public.telemetry_due_for_purge(100)
      where telemetry_id = 'd0000032-0000-4000-8000-000000000032'),
    0::bigint,
    'a run inside the window is kept'
);

select is(
    (select count(*) from public.telemetry_due_for_purge(100)
      where telemetry_id = 'd0000033-0000-4000-8000-000000000033'),
    0::bigint,
    'a run that was never scored is NEVER purged, however old — the blob is '
    'the only copy of a drive somebody did'
);

select is(
    (select count(*) from public.telemetry_due_for_purge(100)
      where telemetry_id = 'd0000034-0000-4000-8000-000000000034'),
    0::bigint,
    'a failed run keeps its telemetry, so it can still be re-driven'
);

-- ── the batch is a real limit ────────────────────────────────────────────

select is(
    (select count(*) from public.telemetry_due_for_purge(1)),
    1::bigint,
    'the batch size bounds one invocation'
);

select is(
    (select telemetry_id from public.telemetry_due_for_purge(1)),
    'd0000030-0000-4000-8000-000000000030'::uuid,
    'and the oldest goes first, so a backlog drains in age order'
);

-- ── marking ──────────────────────────────────────────────────────────────

select is(
    public.mark_telemetry_purged(array['d0000030-0000-4000-8000-000000000030']::uuid[]),
    1,
    'marking a purged blob reports one row'
);

select isnt(
    (select purged_at from public.telemetry
      where id = 'd0000030-0000-4000-8000-000000000030'),
    null,
    'and the envelope records when the blob went'
);

select is(
    (select count(*) from public.telemetry
      where id = 'd0000030-0000-4000-8000-000000000030'),
    1::bigint,
    'the ENVELOPE survives the blob — hash and counts are the record that '
    'the data existed'
);

select is(
    (select count(*) from public.telemetry_due_for_purge(100)
      where telemetry_id = 'd0000030-0000-4000-8000-000000000030'),
    0::bigint,
    'a purged blob is not offered again'
);

select is(
    public.mark_telemetry_purged(array['d0000030-0000-4000-8000-000000000030']::uuid[]),
    0,
    're-marking is a no-op, because a retry after a half-finished batch is '
    'the normal case and must not error'
);

-- ── the window is data, and clients cannot move it ───────────────────────

update public.retention_policy set telemetry_days = 365;

select is(
    (select count(*) from public.telemetry_due_for_purge(100)),
    0::bigint,
    'widening the window immediately un-dues everything inside it — the '
    'oldest run here is 200 days old, so at a year nothing is due'
);

update public.retention_policy set telemetry_days = 90;

-- ── the backlog is visible ───────────────────────────────────────────────

select is(
    (select due_count from public.telemetry_purge_backlog()),
    1::bigint,
    'the backlog counts what is still due — a purge that stops running is '
    'otherwise completely silent'
);

-- ── nobody but the server may do any of this ─────────────────────────────

set local role authenticated;
set local request.jwt.claims = '{"sub":"d0000001-0000-4000-8000-000000000001","role":"authenticated"}';

select throws_ok(
    $$select public.mark_telemetry_purged(array[]::uuid[])$$,
    '42501',
    null,
    'a driver cannot mark telemetry purged'
);

rollback;
