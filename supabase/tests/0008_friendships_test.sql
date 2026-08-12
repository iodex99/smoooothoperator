-- pgTAP tests for migration 0008: friendship state machine + friends-tier visibility.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

select has_table('public', 'friendships', 'friendships table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.friendships'::regclass), 'RLS on friendships');

-- ── Fixtures: alice, bob (will be friends), mallory (stranger) ────────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'alice@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'bob@example.com'),
    ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'mallory@example.com');

-- ── Request flow ──────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

insert into public.friendships (requester_id, addressee_id)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

select is(
    (select status from public.friendships limit 1),
    'pending',
    'alice sent bob a request'
);

select throws_ok(
    $$ insert into public.friendships (requester_id, addressee_id)
       values ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333') $$,
    '42501',
    null,
    'nobody can send requests on someone else''s behalf'
);

-- The requester's illegal self-accept is silently filtered by RLS (0 rows).
update public.friendships set status = 'accepted';

reset role;

select is(
    (select status from public.friendships limit 1),
    'pending',
    'the REQUESTER cannot accept their own request'
);

select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

update public.friendships set status = 'accepted'
where addressee_id = '22222222-2222-2222-2222-222222222222';

select is(
    (select status from public.friendships limit 1),
    'accepted',
    'bob accepted the request'
);

select isnt(
    (select responded_at from public.friendships limit 1),
    null,
    'acceptance stamps responded_at'
);

select throws_ok(
    $$ update public.friendships set status = 'pending' $$,
    'P0001',
    null,
    'a resolved request never reopens'
);

reset role;

select ok(
    public.are_friends('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'),
    'are_friends sees the accepted pair (both directions)'
);
select ok(
    not public.are_friends('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333'),
    'are_friends rejects strangers'
);

-- Duplicate pair in the opposite direction is blocked.
select throws_ok(
    $$ insert into public.friendships (requester_id, addressee_id)
       values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111') $$,
    '23505',
    null,
    'one relationship per pair, regardless of direction'
);

-- ── Privacy: mallory sees nothing ─────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "33333333-3333-3333-3333-333333333333", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.friendships),
    0,
    'third parties cannot see other people''s friendships'
);

reset role;

-- ── Friends-tier visibility upgrades ──────────────────────────────────────
insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, visibility, status)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'Friends Only Loop',
        '11111111-1111-1111-1111-111111111111', 'US', 5000, 3, 7,
        'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7700 34.0300)'::extensions.geography,
        'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
        'SRID=4326;POINT(-118.7700 34.0300)'::extensions.geography,
        'friends', 'active');

insert into public.runs (id, user_id, course_id, status, verification, started_at)
values ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000001', 'scored', 'verified', now());

update public.profiles set ghost_visibility = 'friends'
where id = '11111111-1111-1111-1111-111111111111';

insert into public.ghosts (run_id, course_id, user_id, trajectory, score, duration_seconds)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        '{"points": [[0, 0], [1, 90]], "totalSeconds": 90}', 9500, 90);

-- Bob (friend) sees the friends-only course and ghost…
select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.courses where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    1,
    'friends see friends-visibility courses'
);
select is(
    (select count(*)::int from public.ghosts
     where course_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    1,
    'friends race friends-tier ghosts'
);

reset role;

-- …mallory (stranger) sees neither.
select set_config('request.jwt.claims',
    '{"sub": "33333333-3333-3333-3333-333333333333", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.courses where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    0,
    'strangers never see friends-visibility courses'
);
select is(
    (select count(*)::int from public.ghosts
     where course_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    0,
    'strangers never race friends-tier ghosts'
);

reset role;

select * from finish();
rollback;
