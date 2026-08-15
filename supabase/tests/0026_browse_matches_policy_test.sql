-- `courses_near` and `courses_in_region` are SECURITY DEFINER: they bypass
-- RLS and re-apply the visibility rules themselves, because the PostGIS
-- predicates are not LEAKPROOF and so cannot use an index underneath a row
-- security barrier. That buys a 127 ms -> 11.8 ms browse and costs a trust
-- boundary.
--
-- Migration 0025 claimed the inlined predicate was "the SAME expression as
-- the RLS policy, so the two cannot drift into disagreeing". That claim was
-- WRONG WHEN IT WAS WRITTEN: the policy grants a creator their own course at
-- ANY status, while the inlined copy requires status = 'active' on every
-- branch. The difference is in the safe direction — browse is strictly more
-- restrictive than the policy — but a comment asserting an equivalence is
-- not a check, and the next edit to either side has nothing stopping it.
--
-- So this file does not compare the two texts. It compares the two ANSWERS,
-- against a matrix that covers every combination of visibility, status,
-- ownership and friendship. The expected set is re-derived from the LIVE
-- POLICY on every run by querying the table directly as the same user, so
-- editing the policy updates the expectation automatically and any real
-- divergence fails here.

begin;
select plan(6);

insert into auth.users (id, email) values
    ('bd000001-0000-4000-8000-000000000001', 'me@test.local'),
    ('bd000002-0000-4000-8000-000000000002', 'myfriend@test.local'),
    ('bd000003-0000-4000-8000-000000000003', 'stranger@test.local');

insert into public.friendships (requester_id, addressee_id, status)
values ('bd000001-0000-4000-8000-000000000001',
        'bd000002-0000-4000-8000-000000000002', 'accepted');

-- Every combination that can decide visibility, all within a few hundred
-- metres of each other so one spatial query sees them all.
do $$
declare
    spec record;
    lon double precision;
begin
    for spec in
        select * from (values
            ('public',  'active',  'bd000001-0000-4000-8000-000000000001'),
            ('public',  'draft', 'bd000001-0000-4000-8000-000000000001'),
            ('public',  'active',  null),
            ('private', 'active',  'bd000001-0000-4000-8000-000000000001'),
            ('private', 'draft', 'bd000001-0000-4000-8000-000000000001'),
            ('private', 'active',  'bd000003-0000-4000-8000-000000000003'),
            ('friends', 'active',  'bd000002-0000-4000-8000-000000000002'),
            ('friends', 'draft', 'bd000002-0000-4000-8000-000000000002'),
            ('friends', 'active',  'bd000003-0000-4000-8000-000000000003'),
            ('friends', 'active',  null)
        ) as t(visibility, status, creator)
    loop
        lon := -172.5 + (random() * 0.001);
        insert into public.courses (
            name, country, distance_meters, difficulty, turn_count,
            geometry, start_point, finish_point,
            status, visibility, creator_id
        ) values (
            spec.visibility || '/' || spec.status || '/' ||
                coalesce(left(spec.creator, 10), 'nobody'),
            'ZZ', 4000, 3, 12,
            extensions.st_setsrid(extensions.st_makeline(
                extensions.st_makepoint(lon, -55.5),
                extensions.st_makepoint(lon + 0.01, -55.5)), 4326)::extensions.geography,
            extensions.st_setsrid(extensions.st_makepoint(lon, -55.5), 4326)::extensions.geography,
            extensions.st_setsrid(extensions.st_makepoint(lon + 0.01, -55.5), 4326)::extensions.geography,
            spec.status, spec.visibility, spec.creator::uuid
        );
    end loop;
end $$;

-- ── the differential ──────────────────────────────────────────────────────
--
-- Expected = what THIS user can actually SELECT under the live policy,
-- narrowed to what browse is for (active courses in range). Nothing here
-- restates the rule; it asks the policy.

create or replace function pg_temp.browse_matches_policy(p_user uuid)
returns boolean
language plpgsql
as $$
declare
    from_function uuid[];
    from_policy uuid[];
begin
    select coalesce(array_agg(id order by id), '{}')
      into from_function
      from public.courses_near(-55.5, -172.5, 50000, 100);

    select coalesce(array_agg(id order by id), '{}')
      into from_policy
      from public.courses c
     where c.status = 'active'
       and extensions.st_dwithin(
               c.start_point,
               extensions.st_setsrid(
                   extensions.st_makepoint(-172.5, -55.5), 4326)::extensions.geography,
               50000);

    return from_function = from_policy;
end $$;

set local role authenticated;

set local request.jwt.claims = '{"sub":"bd000001-0000-4000-8000-000000000001","role":"authenticated"}';
select ok(pg_temp.browse_matches_policy('bd000001-0000-4000-8000-000000000001'),
    'a creator sees exactly what the policy allows them — no more, no less');

set local request.jwt.claims = '{"sub":"bd000002-0000-4000-8000-000000000002","role":"authenticated"}';
select ok(pg_temp.browse_matches_policy('bd000002-0000-4000-8000-000000000002'),
    'a friend of the creator sees exactly what the policy allows them');

set local request.jwt.claims = '{"sub":"bd000003-0000-4000-8000-000000000003","role":"authenticated"}';
select ok(pg_temp.browse_matches_policy('bd000003-0000-4000-8000-000000000003'),
    'a stranger sees exactly what the policy allows them');

-- ── the properties that must hold whatever the policy says ────────────────

set local request.jwt.claims = '{"sub":"bd000003-0000-4000-8000-000000000003","role":"authenticated"}';

select is(
    (select count(*) from public.courses_near(-55.5, -172.5, 50000, 100)
      where name like 'private/%/bd000001-0%'),
    0::bigint,
    'a stranger never sees someone else''s private course through the DEFINER path'
);

select is(
    (select count(*) from public.courses_near(-55.5, -172.5, 50000, 100)
      where name like '%/draft/%'),
    0::bigint,
    'no one is offered a course that is not active — you cannot drive it'
);

-- friends-visibility owned by a stranger: this user is NOT their friend.
select is(
    (select count(*) from public.courses_near(-55.5, -172.5, 50000, 100)
      where name = 'friends/active/bd000002-0'),
    0::bigint,
    'a friends-only course stays hidden from someone who is not a friend'
);

select * from finish();
rollback;
