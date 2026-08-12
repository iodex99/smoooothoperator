-- pgTAP tests for migrations 0011-0012: achievements + subscription mirror.
begin;
create extension if not exists pgtap with schema extensions;

select plan(10);

select has_table('public', 'achievements', 'achievements exists');
select has_table('public', 'subscriptions', 'subscriptions exists');
select has_function('public', 'has_active_pro', 'entitlement helper exists');

insert into auth.users (instance_id, id, aud, role, email)
values
    ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'pro@example.com'),
    ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'free@example.com');

insert into public.achievements (user_id, kind)
values ('11111111-1111-1111-1111-111111111111', 'first_run');

insert into public.subscriptions
    (user_id, product_id, original_transaction_id, latest_transaction_id, status, expires_at)
values
    ('11111111-1111-1111-1111-111111111111', 'smooooth.pro.monthly',
     'orig-1', 'tx-9', 'active', now() + interval '20 days');

select throws_ok(
    $$ insert into public.achievements (user_id, kind)
       values ('11111111-1111-1111-1111-111111111111', 'first_run') $$,
    '23505',
    null,
    'achievements are awarded once'
);

select ok(
    public.has_active_pro('11111111-1111-1111-1111-111111111111'),
    'active subscription grants Pro'
);
select ok(
    not public.has_active_pro('22222222-2222-2222-2222-222222222222'),
    'no subscription, no Pro'
);

-- Expired subscriptions grant nothing.
update public.subscriptions set status = 'expired', expires_at = now() - interval '1 day'
where original_transaction_id = 'orig-1';
select ok(
    not public.has_active_pro('11111111-1111-1111-1111-111111111111'),
    'expired subscription revokes Pro'
);

-- ── Client isolation ──────────────────────────────────────────────────────
select set_config('request.jwt.claims',
    '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true);
set local role authenticated;

select is(
    (select count(*)::int from public.achievements),
    1,
    'achievements are public bragging rights'
);

select is(
    (select count(*)::int from public.subscriptions),
    0,
    'users never see anyone else''s subscription state'
);

select throws_ok(
    $$ insert into public.subscriptions
           (user_id, product_id, original_transaction_id, latest_transaction_id, status)
       values ('22222222-2222-2222-2222-222222222222', 'smooooth.pro.yearly',
               'forged', 'forged', 'active') $$,
    '42501',
    null,
    'clients can NEVER self-report entitlement (spec §73)'
);

reset role;

select * from finish();
rollback;
