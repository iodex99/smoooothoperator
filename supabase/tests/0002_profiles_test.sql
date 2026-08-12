-- pgTAP tests for migration 0002: profiles schema, RLS matrix, signup trigger.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

-- ── Schema ────────────────────────────────────────────────────────────────
select has_table('public', 'profiles', 'profiles table exists');

select ok(
    (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass),
    'RLS is enabled on profiles'
);

select policies_are(
    'public', 'profiles',
    array['profiles are publicly readable', 'users update own profile'],
    'exactly the expected policies exist (no insert/delete policies)'
);

select has_trigger('public', 'profiles', 'profiles_set_updated_at', 'updated_at trigger exists');
select has_trigger('auth', 'users', 'on_auth_user_created', 'signup trigger exists on auth.users');

-- ── Fixtures: two signed-up users ─────────────────────────────────────────
insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
     'authenticated', 'authenticated', 'driver1@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
     'authenticated', 'authenticated', 'driver2@example.com');

-- ── Signup trigger behavior ───────────────────────────────────────────────
select is(
    (select count(*)::int from public.profiles
     where id = '11111111-1111-1111-1111-111111111111'),
    1,
    'signup trigger created a profile for the new user'
);

select matches(
    (select username from public.profiles
     where id = '11111111-1111-1111-1111-111111111111'),
    '^[a-z0-9_]{3,20}$',
    'generated username satisfies the format constraint'
);

-- ── Constraints ───────────────────────────────────────────────────────────
select throws_ok(
    $$ update public.profiles
       set username = (select username from public.profiles
                       where id = '11111111-1111-1111-1111-111111111111')
       where id = '22222222-2222-2222-2222-222222222222' $$,
    '23505',
    null,
    'duplicate usernames are rejected'
);

select throws_ok(
    $$ update public.profiles set username = 'AB'
       where id = '11111111-1111-1111-1111-111111111111' $$,
    '23514',
    null,
    'usernames violating the format constraint are rejected'
);

select throws_ok(
    $$ update public.profiles set country = 'USA'
       where id = '11111111-1111-1111-1111-111111111111' $$,
    '23514',
    null,
    'country must be ISO 3166-1 alpha-2'
);

-- ── RLS: authenticated user ───────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

select ok(
    exists(select 1 from public.profiles
           where id = '22222222-2222-2222-2222-222222222222'),
    'authenticated users can read other profiles (leaderboard identity)'
);

update public.profiles set display_name = 'Driver One'
where id = '11111111-1111-1111-1111-111111111111';

select is(
    (select display_name from public.profiles
     where id = '11111111-1111-1111-1111-111111111111'),
    'Driver One',
    'users can update their own profile'
);

update public.profiles set display_name = 'hacked'
where id = '22222222-2222-2222-2222-222222222222';

select throws_ok(
    $$ update public.profiles set rating = 9999
       where id = '11111111-1111-1111-1111-111111111111' $$,
    '42501',
    null,
    'users cannot update their own rating (server-computed column)'
);

reset role;

select is(
    (select display_name from public.profiles
     where id = '22222222-2222-2222-2222-222222222222'),
    '',
    'updating someone else''s profile silently affects zero rows'
);

-- ── RLS: anonymous ────────────────────────────────────────────────────────
select set_config('request.jwt.claims', '{"role": "anon"}', true);
set local role anon;

select ok(
    exists(select 1 from public.profiles),
    'anonymous visitors can read profiles (challenge share links)'
);

select throws_ok(
    $$ insert into public.profiles (id, username)
       values (extensions.gen_random_uuid(), 'sneaky_anon') $$,
    '42501',
    null,
    'anonymous visitors cannot insert profiles'
);

reset role;

select * from finish();
rollback;
