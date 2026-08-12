-- pgTAP tests for migration 0003: scoring_configs.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

select has_table('public', 'scoring_configs', 'scoring_configs table exists');

select ok(
    (select relrowsecurity from pg_class where oid = 'public.scoring_configs'::regclass),
    'RLS is enabled on scoring_configs'
);

-- Fixtures (as superuser — represents the service role path). The local
-- seed ships an active 1.0.0 row; park it so this test owns "active".
update public.scoring_configs set active = false;

insert into public.scoring_configs (version, config, active)
values
    ('9.0.0', '{"weights": {"paceBps": 3500}}', false),
    ('9.1.0', '{"weights": {"paceBps": 3500}}', true);

select throws_ok(
    $$ insert into public.scoring_configs (version, config, active)
       values ('9.2.0', '{}', true) $$,
    '23505',
    null,
    'only one config can be active at a time'
);

select throws_ok(
    $$ insert into public.scoring_configs (version, config)
       values ('v2', '{}') $$,
    '23514',
    null,
    'version must be semver-shaped'
);

-- Anonymous can read (clients need the config for provisional scoring)…
select set_config('request.jwt.claims', '{"role": "anon"}', true);
set local role anon;

select is(
    (select count(*)::int from public.scoring_configs where version like '9.%'),
    2,
    'anon can read scoring configs'
);

select throws_ok(
    $$ insert into public.scoring_configs (version, config)
       values ('9.9.9', '{}') $$,
    '42501',
    null,
    'anon cannot insert scoring configs'
);

reset role;

-- …authenticated can read but not write.
select set_config('request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select version from public.scoring_configs where active),
    '9.1.0',
    'authenticated can read the active config'
);

select throws_ok(
    $$ update public.scoring_configs set active = false where version = '9.1.0' $$,
    '42501',
    null,
    'authenticated cannot modify scoring configs'
);

reset role;

select * from finish();
rollback;
