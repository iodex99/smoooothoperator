-- A course is made by recording a drive, so its line is a road the creator
-- drove — often starting where they set off from. Until this function there
-- was no DELETE policy on courses at all and nothing ever set status to
-- 'archived', so a course once created was permanent.

begin;
select plan(9);

insert into auth.users (id, email) values
    ('c0000001-0000-4000-8000-000000000001', 'creator@test.local'),
    ('c0000002-0000-4000-8000-000000000002', 'someoneelse@test.local');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status, visibility, creator_id
)
select id, nm, 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-176.5, -60.5),
        extensions.st_makepoint(-176.4, -60.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-176.5, -60.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-176.4, -60.5), 4326)::extensions.geography,
    'active', 'public', creator
from (values
    ('c0000010-0000-4000-8000-000000000010'::uuid, 'Road By My House',
     'c0000001-0000-4000-8000-000000000001'::uuid),
    ('c0000011-0000-4000-8000-000000000011'::uuid, 'Road Others Race',
     'c0000001-0000-4000-8000-000000000001'::uuid),
    ('c0000012-0000-4000-8000-000000000012'::uuid, 'Not Mine',
     'c0000002-0000-4000-8000-000000000002'::uuid)
) t(id, nm, creator);

-- somebody else has driven the second one
insert into public.runs (id, user_id, course_id, status, verification, score, started_at, completed_at)
values ('c0000020-0000-4000-8000-000000000020', 'c0000002-0000-4000-8000-000000000002',
        'c0000011-0000-4000-8000-000000000011', 'scored', 'verified', 8000, now(), now());
insert into public.leaderboard_entries (user_id, course_id, run_id, score, duration_seconds)
values ('c0000002-0000-4000-8000-000000000002', 'c0000011-0000-4000-8000-000000000011',
        'c0000020-0000-4000-8000-000000000020', 8000, 190);

set local role authenticated;
set local request.jwt.claims = '{"sub":"c0000001-0000-4000-8000-000000000001","role":"authenticated"}';

-- ── a course nobody drove is theirs alone ─────────────────────────────────

select is(
    public.delete_my_course('c0000010-0000-4000-8000-000000000010'),
    'deleted',
    'a course nobody has driven is deleted outright'
);

select is(
    (select count(*) from public.courses where id = 'c0000010-0000-4000-8000-000000000010'),
    0::bigint,
    'and the row is actually gone, not merely hidden'
);

-- ── a course others drove leaves the catalog without erasing them ─────────

select is(
    public.delete_my_course('c0000011-0000-4000-8000-000000000011'),
    'archived',
    'a course other people have driven is archived, not deleted'
);

select is(
    (select status from public.courses where id = 'c0000011-0000-4000-8000-000000000011'),
    'archived',
    'its status says so'
);

-- Checked as the owner, not as the creator: RLS quite rightly hides another
-- driver's run from them, so asking as `authenticated` would count zero and
-- "survives" would pass for the wrong reason.
reset role;

select is(
    (select count(*) from public.runs where course_id = 'c0000011-0000-4000-8000-000000000011'),
    1::bigint,
    'the other driver''s run survives — it is their record, not the creator''s'
);

select is(
    (select count(*) from public.leaderboard_entries
      where course_id = 'c0000011-0000-4000-8000-000000000011'),
    1::bigint,
    'and so does their leaderboard entry'
);

-- Archived means out of the catalog: browse filters on status = 'active'.
-- Back to a driver, because that is who browse answers.
set local role authenticated;
set local request.jwt.claims = '{"sub":"c0000001-0000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select count(*) from public.courses_near(-60.5, -176.5, 50000, 100)
      where id = 'c0000011-0000-4000-8000-000000000011'),
    0::bigint,
    'an archived course is no longer offered to anyone'
);

-- ── somebody else's course is not theirs to remove ────────────────────────

select throws_ok(
    $$ select public.delete_my_course('c0000012-0000-4000-8000-000000000012') $$,
    'P0002',
    null,
    'a course somebody else created cannot be removed'
);

select is(
    (select count(*) from public.courses where id = 'c0000012-0000-4000-8000-000000000012'),
    1::bigint,
    'and it is still there'
);

select * from finish();
rollback;
