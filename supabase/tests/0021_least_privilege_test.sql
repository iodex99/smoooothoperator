-- TRUNCATE bypasses row-level security. Every policy in this schema is
-- irrelevant to it, so a client holding that privilege can empty a table no
-- matter how carefully its rules are written.

begin;
select plan(9);

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

select * from finish();
rollback;
