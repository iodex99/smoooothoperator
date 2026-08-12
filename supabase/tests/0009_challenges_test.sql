-- pgTAP tests for migration 0009: challenge membership, joins, state machine.
begin;
create extension if not exists pgtap with schema extensions;

select plan(15);

select has_table('public', 'challenges', 'challenges table exists');
select has_table('public', 'challenge_participants', 'participants table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.challenges'::regclass), 'RLS on challenges');
select ok((select relrowsecurity from pg_class where oid = 'public.challenge_participants'::regclass), 'RLS on participants');

-- ── Fixtures ──────────────────────────────────────────────────────────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'david@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'sarah@example.com'),
    ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'mallory@example.com');

insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, visibility, status)
values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'Public Course', null, 'US', 5000, 3, 7,
     'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7700 34.0300)'::extensions.geography,
     'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
     'SRID=4326;POINT(-118.7700 34.0300)'::extensions.geography,
     'public', 'active'),
    ('aaaaaaaa-0000-0000-0000-000000000002', 'Sarahs Private Course',
     '22222222-2222-2222-2222-222222222222', 'US', 5000, 3, 7,
     'SRID=4326;LINESTRING(-118.50 34.10, -118.48 34.11)'::extensions.geography,
     'SRID=4326;POINT(-118.50 34.10)'::extensions.geography,
     'SRID=4326;POINT(-118.48 34.11)'::extensions.geography,
     'private', 'active');

-- ── David creates challenges ──────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

insert into public.challenges (id, course_id, creator_id, type, name)
values ('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'public', 'Beat my 9612');

insert into public.challenges (id, course_id, creator_id, type, name)
values ('cccccccc-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'private', 'Inner circle only');

select is(
    (select count(*)::int from public.challenges),
    2,
    'creator sees both of their challenges'
);

select throws_ok(
    $$ insert into public.challenges (course_id, creator_id, type)
       values ('aaaaaaaa-0000-0000-0000-000000000002',
               '11111111-1111-1111-1111-111111111111', 'friend') $$,
    '42501',
    null,
    'cannot create a challenge on a course you cannot see'
);

select ok(
    (select invite_code from public.challenges
     where id = 'cccccccc-0000-0000-0000-000000000001') ~ '^[0-9A-F]{10}$',
    'challenges get share-ready invite codes'
);

reset role;

-- ── Sarah self-joins the public challenge, not the private one ────────────
select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

insert into public.challenge_participants (challenge_id, user_id)
values ('cccccccc-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

select is(
    (select count(*)::int from public.challenge_participants
     where user_id = '22222222-2222-2222-2222-222222222222'),
    1,
    'anyone can join a public challenge'
);

select throws_ok(
    $$ insert into public.challenge_participants (challenge_id, user_id)
       values ('cccccccc-0000-0000-0000-000000000002',
               '22222222-2222-2222-2222-222222222222') $$,
    '42501',
    null,
    'private challenges cannot be self-joined (invite path only)'
);

-- Sarah records a run and links it; linking someone else's run is blocked.
insert into public.runs (id, user_id, course_id, status, started_at)
values ('bbbbbbbb-0000-0000-0000-000000000010', '22222222-2222-2222-2222-222222222222',
        'aaaaaaaa-0000-0000-0000-000000000001', 'recording', now());

update public.challenge_participants
set run_id = 'bbbbbbbb-0000-0000-0000-000000000010'
where challenge_id = 'cccccccc-0000-0000-0000-000000000001'
  and user_id = '22222222-2222-2222-2222-222222222222';

select is(
    (select run_id::text from public.challenge_participants
     where user_id = '22222222-2222-2222-2222-222222222222'),
    'bbbbbbbb-0000-0000-0000-000000000010',
    'participants link their own runs'
);

reset role;

insert into public.runs (id, user_id, course_id, status, started_at)
values ('bbbbbbbb-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000001', 'recording', now());

select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

select throws_ok(
    $$ update public.challenge_participants
       set run_id = 'bbbbbbbb-0000-0000-0000-000000000011'
       where user_id = '22222222-2222-2222-2222-222222222222' $$,
    '42501',
    null,
    'linking someone else''s run is blocked'
);

reset role;

-- ── Mallory (outsider) sees the public challenge, not the private one ─────
select set_config('request.jwt.claims',
    '{"sub": "33333333-3333-3333-3333-333333333333", "role": "authenticated"}', true);
set local role authenticated;

select results_eq(
    $$ select id::text from public.challenges order by id $$,
    array['cccccccc-0000-0000-0000-000000000001'],
    'outsiders see only public challenges'
);

select is(
    (select count(*)::int from public.challenge_participants
     where challenge_id = 'cccccccc-0000-0000-0000-000000000002'),
    0,
    'outsiders cannot enumerate private participant lists'
);

reset role;

-- ── State machine (spec §69) ──────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

update public.challenges set status = 'completed'
where id = 'cccccccc-0000-0000-0000-000000000001';

select is(
    (select status from public.challenges where id = 'cccccccc-0000-0000-0000-000000000001'),
    'completed',
    'active challenges can complete'
);

select throws_ok(
    $$ update public.challenges set status = 'active'
       where id = 'cccccccc-0000-0000-0000-000000000001' $$,
    'P0001',
    null,
    'completed challenges never resurrect (spec §69)'
);

reset role;

select * from finish();
rollback;
