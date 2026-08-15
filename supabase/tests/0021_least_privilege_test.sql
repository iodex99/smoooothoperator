-- TRUNCATE bypasses row-level security. Every policy in this schema is
-- irrelevant to it, so a client holding that privilege can empty a table no
-- matter how carefully its rules are written.

begin;
select plan(11);

-- ── the privilege is gone from every table ────────────────────────────────

select is(
    (select count(*)::int
       from information_schema.role_table_grants
      where table_schema = 'public'
        and grantee in ('anon', 'authenticated')
        and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')),
    0,
    'no client role holds TRUNCATE, REFERENCES or TRIGGER on any table'
);

-- ── and it cannot be exercised ────────────────────────────────────────────

insert into auth.users (id, email)
values ('de000001-a000-4000-8000-000000000001', 'leastpriv@test.local');

set local role authenticated;
set local request.jwt.claims = '{"sub":"de000001-a000-4000-8000-000000000001","role":"authenticated"}';

select throws_ok(
    'truncate table public.courses',
    '42501',
    null,
    'a signed-in driver cannot truncate the catalog'
);

select throws_ok(
    'truncate table public.runs',
    '42501',
    null,
    'nor everyone''s runs'
);

select throws_ok(
    'truncate table public.leaderboard_entries',
    '42501',
    null,
    'nor the leaderboards'
);

select throws_ok(
    'truncate table public.profiles',
    '42501',
    null,
    'nor the user base'
);

-- ── the app still works ───────────────────────────────────────────────────
-- Revoking too much is its own outage, so the privileges the app actually
-- uses are asserted here rather than assumed.

select ok(
    has_table_privilege('authenticated', 'public.courses', 'select'),
    'browsing the catalog still works'
);

select ok(
    has_table_privilege('authenticated', 'public.vehicles', 'insert'),
    'adding a car still works'
);

select ok(
    has_table_privilege('authenticated', 'public.vehicles', 'delete'),
    'removing a car still works'
);

select ok(
    has_table_privilege('authenticated', 'public.telemetry', 'insert'),
    'uploading a run''s telemetry still works'
);

-- ── the telemetry bucket has ceilings, not just doors ─────────────────────
--
-- Back to the owner role: the assertions above deliberately run as
-- `authenticated`, which cannot read storage.buckets at all — so leaving the
-- role set would make these two pass or fail for the wrong reason.
reset role;

--
-- Who may write there was always right. How much they may write was
-- unbounded: file_size_limit was NULL, so any account could upload objects
-- of any size under a prefix it controls, and storage is billed by the
-- gigabyte.

select ok(
    (select file_size_limit from storage.buckets where id = 'telemetry') is not null,
    'the telemetry bucket caps object size — an unbounded write path on a '
    'free-to-create account is a bill somebody else pays'
);

select ok(
    (select not public from storage.buckets where id = 'telemetry'),
    'and it is not a public bucket — these are raw GPS traces'
);

select * from finish();
rollback;
