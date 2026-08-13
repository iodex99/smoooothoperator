-- pgTAP for migration 0016: SECURITY DEFINER trust boundaries.
-- Every assertion here corresponds to a live exploit from the round-4
-- adversarial review.
begin;
create extension if not exists pgtap with schema extensions;

select plan(6);

insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', 'c1111111-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'trust-a@example.com'),
    ('00000000-0000-0000-0000-000000000000', 'c2222222-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'trust-b@example.com');

insert into public.courses
    (id, name, creator_id, country, distance_meters, difficulty, turn_count,
     geometry, start_point, finish_point, visibility, status)
values ('dddddddd-0000-0000-0000-000000000001', 'Trust Course', null, 'US', 5000, 3, 10,
        extensions.st_geogfromtext('LINESTRING(-118.5 34.0, -118.48 34.02)'),
        extensions.st_geogfromtext('POINT(-118.5 34.0)'),
        extensions.st_geogfromtext('POINT(-118.48 34.02)'), 'public', 'active');

insert into public.runs (id, user_id, course_id, status, started_at)
values ('eeeeeeee-0000-0000-0000-000000000001', 'c1111111-0000-0000-0000-000000000001',
        'dddddddd-0000-0000-0000-000000000001', 'recording', now());

select set_config('request.jwt.claims',
    '{"sub": "c1111111-0000-0000-0000-000000000001", "role": "authenticated"}', true);
set local role authenticated;

-- ── The status guard must actually fire ───────────────────────────────────
-- It was SECURITY DEFINER, so current_user was always `postgres` and the
-- guard short-circuited on every call: a client could set any status.
select throws_ok(
    $$ update public.runs set status = 'scored'
        where id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
    '42501',
    null,
    'a client cannot mark its own run scored'
);

select lives_ok(
    $$ update public.runs set status = 'uploaded'
        where id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
    'but the one transition the upload flow owns still works'
);

select throws_ok(
    $$ update public.runs set status = 'processing'
        where id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
    '42501',
    null,
    'and it cannot walk into the pipeline''s states afterwards'
);

-- ── Cross-user probing ────────────────────────────────────────────────────
-- challenge_candidates leaked which courses ANY user had driven, plus their
-- friend graph, by passing a victim's id.
select throws_ok(
    $$ select * from public.challenge_candidates(
        'c2222222-0000-0000-0000-000000000002', 34.0, -118.5, 10000, now() - interval '1 day') $$,
    '42501',
    null,
    'clients cannot call the candidate search at all'
);

-- course_route must ignore a supplied id and use the caller's own.
select ok(
    public.course_route('c2222222-0000-0000-0000-000000000002',
                        'dddddddd-0000-0000-0000-000000000001') is not null,
    'course_route still serves a public course to the caller'
);

reset role;

-- ── Public text cannot be unbounded ───────────────────────────────────────
select throws_ok(
    $$ update public.profiles set display_name = repeat('x', 5000)
        where id = 'c1111111-0000-0000-0000-000000000001' $$,
    '23514',
    null,
    'a half-megabyte display name is refused'
);

select * from finish();
rollback;
