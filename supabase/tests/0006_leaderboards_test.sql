-- pgTAP tests for migration 0006: leaderboard visibility, write protection, ranking.
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

select has_table('public', 'leaderboard_entries', 'leaderboard_entries exists');
select has_view('public', 'course_leaderboards', 'ranked view exists');
select ok(
    (select relrowsecurity from pg_class where oid = 'public.leaderboard_entries'::regclass),
    'RLS on leaderboard_entries'
);

-- ── Fixtures: three drivers, one course, three scored runs ────────────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'alex@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'sarah@example.com'),
    ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'mike@example.com');

insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, visibility, status)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'Malibu 042', null, 'US', 20600, 4, 23,
        'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7050 34.0480)'::extensions.geography,
        'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
        'SRID=4326;POINT(-118.7050 34.0480)'::extensions.geography,
        'public', 'active');

insert into public.runs (id, user_id, course_id, status, verification, started_at, score, duration_seconds)
values
    ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
     'aaaaaaaa-0000-0000-0000-000000000001', 'scored', 'verified', now(), 9812, 1121),
    ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
     'aaaaaaaa-0000-0000-0000-000000000001', 'scored', 'verified', now(), 9781, 1130),
    ('bbbbbbbb-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333',
     'aaaaaaaa-0000-0000-0000-000000000001', 'scored', 'verified', now(), 9781, 1119);

insert into public.leaderboard_entries (course_id, user_id, run_id, score, duration_seconds, smoothness_bps)
values
    ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
     'bbbbbbbb-0000-0000-0000-000000000001', 9812, 1121, 9620),
    ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
     'bbbbbbbb-0000-0000-0000-000000000002', 9781, 1130, 9510),
    ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
     'bbbbbbbb-0000-0000-0000-000000000003', 9781, 1119, 9540);

-- ── Ranking semantics ─────────────────────────────────────────────────────
select results_eq(
    $$ select rank::int, user_id::text from public.course_leaderboards
       where course_id = 'aaaaaaaa-0000-0000-0000-000000000001' order by rank $$,
    $$ values
        (1, '11111111-1111-1111-1111-111111111111'),
        (2, '33333333-3333-3333-3333-333333333333'),
        (3, '22222222-2222-2222-2222-222222222222') $$,
    'rank orders by score desc, then faster time breaks the tie'
);

select throws_ok(
    $$ insert into public.leaderboard_entries (course_id, user_id, run_id, score, duration_seconds)
       values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
               'bbbbbbbb-0000-0000-0000-000000000002', 9000, 1200) $$,
    '23505',
    null,
    'one best entry per (course, user)'
);

-- ── Access control ────────────────────────────────────────────────────────
select set_config('request.jwt.claims', '{"role": "anon"}', true);
set local role anon;

select is(
    (select count(*)::int from public.leaderboard_entries),
    3,
    'anon reads the leaderboard (share links)'
);

select is(
    (select username from public.course_leaderboards where rank = 1
     and course_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    (select username from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
    'the ranked view joins public identity'
);

select throws_ok(
    $$ insert into public.leaderboard_entries (course_id, user_id, run_id, score, duration_seconds)
       values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
               'bbbbbbbb-0000-0000-0000-000000000001', 10000, 1) $$,
    '42501',
    null,
    'anon cannot write leaderboards'
);

reset role;

select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

select throws_ok(
    $$ insert into public.leaderboard_entries (course_id, user_id, run_id, score, duration_seconds)
       values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
               'bbbbbbbb-0000-0000-0000-000000000001', 10000, 1) $$,
    '42501',
    null,
    'authenticated users cannot write their own leaderboard rows (spec §45)'
);

select throws_ok(
    $$ update public.leaderboard_entries set score = 10000
       where user_id = '11111111-1111-1111-1111-111111111111' $$,
    '42501',
    null,
    'authenticated users cannot inflate existing entries'
);

select throws_ok(
    $$ delete from public.leaderboard_entries
       where user_id = '22222222-2222-2222-2222-222222222222' $$,
    '42501',
    null,
    'authenticated users cannot delete rivals'
);

reset role;

select * from finish();
rollback;
