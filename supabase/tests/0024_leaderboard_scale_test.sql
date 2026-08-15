-- The leaderboard is what the product competes on, so its numbers have to
-- mean what a driver reads them to mean. Two things are asserted here:
-- that a scoped board is ranked WITHIN that scope (the friends board used
-- to read #4,912 for the best of five friends), and that the paging is
-- consistent with the ranks.

begin;
select plan(13);

insert into auth.users (id, email) values
    ('1b000001-a000-4000-8000-000000000001', 'ace@test.local'),
    ('1b000002-b000-4000-8000-000000000002', 'second@test.local'),
    ('1b000003-c000-4000-8000-000000000003', 'third@test.local'),
    ('1b000004-d000-4000-8000-000000000004', 'fourth@test.local');

update public.profiles set country = 'GB'
 where id in ('1b000002-b000-4000-8000-000000000002', '1b000004-d000-4000-8000-000000000004');
update public.profiles set country = 'FR'
 where id in ('1b000001-a000-4000-8000-000000000001', '1b000003-c000-4000-8000-000000000003');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, visibility
) values (
    '1b000010-0000-4000-8000-000000000010', 'Rank Test Road', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-168.5, -44.5),
        extensions.st_makepoint(-168.4, -44.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-168.5, -44.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-168.4, -44.5), 4326)::extensions.geography,
    'active', 'public'
);

-- Four drivers, unambiguous order: 9000 > 8000 > 7000 > 6000.
insert into public.runs (id, user_id, course_id, status, verification, score, started_at, completed_at)
values
    ('1b000021-0000-4000-8000-000000000021', '1b000001-a000-4000-8000-000000000001',
     '1b000010-0000-4000-8000-000000000010', 'scored', 'verified', 9000, now(), now()),
    ('1b000022-0000-4000-8000-000000000022', '1b000002-b000-4000-8000-000000000002',
     '1b000010-0000-4000-8000-000000000010', 'scored', 'verified', 8000, now(), now()),
    ('1b000023-0000-4000-8000-000000000023', '1b000003-c000-4000-8000-000000000003',
     '1b000010-0000-4000-8000-000000000010', 'scored', 'verified', 7000, now(), now()),
    ('1b000024-0000-4000-8000-000000000024', '1b000004-d000-4000-8000-000000000004',
     '1b000010-0000-4000-8000-000000000010', 'scored', 'verified', 6000, now(), now());

insert into public.leaderboard_entries (user_id, course_id, run_id, score, duration_seconds)
values
    ('1b000001-a000-4000-8000-000000000001', '1b000010-0000-4000-8000-000000000010',
     '1b000021-0000-4000-8000-000000000021', 9000, 180),
    ('1b000002-b000-4000-8000-000000000002', '1b000010-0000-4000-8000-000000000010',
     '1b000022-0000-4000-8000-000000000022', 8000, 190),
    ('1b000003-c000-4000-8000-000000000003', '1b000010-0000-4000-8000-000000000010',
     '1b000023-0000-4000-8000-000000000023', 7000, 200),
    ('1b000004-d000-4000-8000-000000000004', '1b000010-0000-4000-8000-000000000010',
     '1b000024-0000-4000-8000-000000000024', 6000, 210);

set local role authenticated;
set local request.jwt.claims = '{"sub":"1b000002-b000-4000-8000-000000000002","role":"authenticated"}';

-- ── the global board ──────────────────────────────────────────────────────

select is(
    (select array_agg(rank order by rank)
       from public.leaderboard_page('1b000010-0000-4000-8000-000000000010')),
    array[1,2,3,4]::bigint[],
    'the global board is ranked 1..4'
);

select is(
    (select user_id from public.leaderboard_page('1b000010-0000-4000-8000-000000000010')
      where rank = 1),
    '1b000001-a000-4000-8000-000000000001'::uuid,
    'the highest score is first'
);

-- ── a scoped board is ranked within its scope ─────────────────────────────
--
-- This is the bug: filtering the old view by country left the global rank
-- attached, so a national board could contain no #1 at all and the numbers
-- jumped arbitrarily. On a friends board — five people — that is the whole
-- point of the screen.

select is(
    (select array_agg(rank order by rank)
       from public.leaderboard_page('1b000010-0000-4000-8000-000000000010', 'GB')),
    array[1,2]::bigint[],
    'the national board starts at #1, not at the leader''s global rank'
);

select is(
    (select user_id from public.leaderboard_page('1b000010-0000-4000-8000-000000000010', 'GB')
      where rank = 1),
    '1b000002-b000-4000-8000-000000000002'::uuid,
    'and #1 nationally is the best driver in that country'
);

select is(
    (select array_agg(rank order by rank)
       from public.leaderboard_page(
           '1b000010-0000-4000-8000-000000000010', null,
           array['1b000003-c000-4000-8000-000000000003',
                 '1b000004-d000-4000-8000-000000000004']::uuid[])),
    array[1,2]::bigint[],
    'a friends board of two reads #1 and #2'
);

-- ── paging ────────────────────────────────────────────────────────────────

select is(
    (select array_agg(rank order by rank)
       from public.leaderboard_page('1b000010-0000-4000-8000-000000000010', null, null, 2, 2)),
    array[3,4]::bigint[],
    'the second page continues the numbering rather than restarting at 1'
);

select is(
    (select count(*) from public.leaderboard_page(
        '1b000010-0000-4000-8000-000000000010', null, null, 100000, 0)),
    2::bigint + 2,
    'an absurd page size is clamped and still returns everyone here'
);

select is(
    (select count(*) from public.leaderboard_page(
        '1b000010-0000-4000-8000-000000000010', null, null, 50, -5)),
    4::bigint,
    'a negative offset is treated as the first page, not as an error'
);

-- ── my own rank, counted rather than derived from ranking everybody ───────

select is(
    public.my_course_rank('1b000010-0000-4000-8000-000000000010'),
    2::bigint,
    'my_course_rank agrees with the board'
);

set local request.jwt.claims = '{"sub":"1b000001-a000-4000-8000-000000000001","role":"authenticated"}';

select is(
    public.my_course_rank('1b000010-0000-4000-8000-000000000010'),
    1::bigint,
    'the leader is rank 1'
);

select is(
    (select wins from public.my_rank_summary()),
    1::bigint,
    'and has one win'
);

set local request.jwt.claims = '{"sub":"1b000004-d000-4000-8000-000000000004","role":"authenticated"}';

select is(
    (select top_ten from public.my_rank_summary()),
    1::bigint,
    'fourth place still counts as a top ten'
);

select is(
    (select verified_runs from public.my_rank_summary()),
    1::bigint,
    'the verified-run count comes back in the same bundle — it used to be a '
    'second request that downloaded one id per run to count them'
);

select * from finish();
rollback;
