-- pgTAP tests for migration 0007: ghost privacy controls (spec §§35, 70).
begin;
create extension if not exists pgtap with schema extensions;

select plan(9);

select has_table('public', 'ghosts', 'ghosts table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.ghosts'::regclass), 'RLS on ghosts');

-- ── Fixtures: an open driver, a private driver, and a spectator ───────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'open@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'private@example.com'),
    ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'spectator@example.com');

update public.profiles set ghost_visibility = 'nobody'
where id = '22222222-2222-2222-2222-222222222222';

insert into public.courses (id, name, creator_id, country, distance_meters, difficulty, turn_count,
                            geometry, start_point, finish_point, visibility, status)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'Ghost Course', null, 'US', 2000, 2, 5,
        'SRID=4326;LINESTRING(-118.7798 34.0259, -118.7700 34.0300)'::extensions.geography,
        'SRID=4326;POINT(-118.7798 34.0259)'::extensions.geography,
        'SRID=4326;POINT(-118.7700 34.0300)'::extensions.geography,
        'public', 'active');

insert into public.runs (id, user_id, course_id, status, verification, started_at)
values
    ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
     'aaaaaaaa-0000-0000-0000-000000000001', 'scored', 'verified', now()),
    ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
     'aaaaaaaa-0000-0000-0000-000000000001', 'scored', 'verified', now());

insert into public.ghosts (run_id, course_id, user_id, trajectory, score, duration_seconds)
values
    ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
     '11111111-1111-1111-1111-111111111111',
     '{"points": [[0, 0], [0.5, 60], [1, 100]], "totalSeconds": 100}', 9400, 100),
    ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
     '22222222-2222-2222-2222-222222222222',
     '{"points": [[0, 0], [1, 95]], "totalSeconds": 95}', 9600, 95);

-- ── Spectator: sees open ghosts, never private ones ───────────────────────
select set_config('request.jwt.claims',
    '{"sub": "33333333-3333-3333-3333-333333333333", "role": "authenticated"}', true);
set local role authenticated;

select results_eq(
    $$ select user_id::text from public.ghosts order by user_id $$,
    array['11111111-1111-1111-1111-111111111111'],
    'spectators see only ghosts whose owner shares with everyone'
);

select throws_ok(
    $$ insert into public.ghosts (run_id, course_id, user_id, trajectory, score, duration_seconds)
       values ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
               '33333333-3333-3333-3333-333333333333', '{}', 10000, 1) $$,
    '42501',
    null,
    'clients cannot forge ghosts (service role only)'
);

reset role;

-- ── The private owner still sees their own ghost ──────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.ghosts
     where user_id = '22222222-2222-2222-2222-222222222222'),
    1,
    'owners always race their own ghosts regardless of privacy setting'
);

select is(
    (select count(*)::int from public.ghosts),
    2,
    'private owner sees own ghost plus public ones'
);

reset role;

-- ── Privacy setting flips take effect immediately ─────────────────────────
update public.profiles set ghost_visibility = 'nobody'
where id = '11111111-1111-1111-1111-111111111111';

select set_config('request.jwt.claims',
    '{"sub": "33333333-3333-3333-3333-333333333333", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.ghosts),
    0,
    'flipping ghost_visibility to nobody hides ghosts at once'
);

reset role;

-- ── Payload shape guard: no coordinates in ghost trajectories ─────────────
select is(
    (select count(*)::int from public.ghosts
     where trajectory::text like '%latitude%' or trajectory::text like '%longitude%'),
    0,
    'ghost trajectories contain no raw coordinates (spec §35)'
);

-- ── Anon has no ghost access (racing requires an account) ────────────────
select set_config('request.jwt.claims', '{"role": "anon"}', true);
set local role anon;

select throws_ok(
    $$ select count(*) from public.ghosts $$,
    '42501',
    null,
    'anonymous visitors cannot enumerate ghosts'
);

reset role;

select * from finish();
rollback;
