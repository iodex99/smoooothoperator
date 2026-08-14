-- The operator dashboard reads every row in the database. These tests are
-- about the gate, not the arithmetic: if the gate is wrong, this migration
-- is a "read the whole user base" endpoint with a friendly name.

begin;
select plan(27);

insert into auth.users (id, email) values
    ('ad000001-a000-4000-8000-000000000001', 'owner@test.local'),
    ('ad000002-b000-4000-8000-000000000002', 'nosy@test.local');

insert into public.admins (user_id, note)
values ('ad000001-a000-4000-8000-000000000001', 'fixture owner');

-- ── the table itself is unreachable from the API ──────────────────────────

select ok(
    not has_table_privilege('anon', 'public.admins', 'select'),
    'anon cannot even select from admins — membership is not public knowledge'
);
select ok(
    not has_table_privilege('authenticated', 'public.admins', 'select'),
    'a signed-in user cannot read who the admins are'
);
select ok(
    not has_table_privilege('authenticated', 'public.admins', 'insert'),
    'nobody can add themselves as an admin through the API'
);
select ok(
    not has_table_privilege('authenticated', 'public.product_prices', 'select'),
    'prices are operator data, not client data'
);

-- ── is_admin() reads auth.uid() and cannot be told who to check ───────────

select is(
    (select count(*)::int from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'is_admin' and p.pronargs > 0),
    0,
    'is_admin() takes no arguments — it cannot be handed someone else''s id'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"ad000001-a000-4000-8000-000000000001","role":"authenticated"}';
select ok(public.is_admin(), 'the owner is an admin');

set local request.jwt.claims = '{"sub":"ad000002-b000-4000-8000-000000000002","role":"authenticated"}';
select ok(not public.is_admin(), 'another signed-in user is not');

-- ── every analytics function refuses a non-admin, loudly ──────────────────

select throws_ok(
    'select * from public.admin_overview()',
    '42501',
    'not authorised',
    'overview refuses a non-admin'
);
select throws_ok(
    'select * from public.admin_courses_by_region()',
    '42501', 'not authorised',
    'courses-by-region refuses a non-admin'
);
select throws_ok(
    'select * from public.admin_top_courses(5)',
    '42501', 'not authorised',
    'top-courses refuses a non-admin'
);
select throws_ok(
    'select * from public.admin_regions_by_activity(30)',
    '42501', 'not authorised',
    'regions-by-activity refuses a non-admin'
);
select throws_ok(
    'select * from public.admin_revenue_by_product()',
    '42501', 'not authorised',
    'revenue refuses a non-admin'
);
select throws_ok(
    'select * from public.admin_growth_daily(30)',
    '42501', 'not authorised',
    'growth refuses a non-admin'
);
select throws_ok(
    'select * from public.admin_retention()',
    '42501', 'not authorised',
    'retention refuses a non-admin'
);

-- A silent empty result would be indistinguishable from "no users yet",
-- which is exactly how a permission bug survives to production.
select ok(
    (select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'admin\_%'
       and p.prosrc not like '%require_admin%'
       and p.proname <> 'admin_mrr_minor') = 0,
    'every admin_* function calls require_admin()'
);

select ok(
    not has_function_privilege('anon', 'public.admin_overview()', 'execute'),
    'anon cannot execute the analytics functions at all'
);

-- ── the owner gets real numbers ───────────────────────────────────────────

set local request.jwt.claims = '{"sub":"ad000001-a000-4000-8000-000000000001","role":"authenticated"}';

select ok(
    (select total_users from public.admin_overview()) >= 2,
    'the owner sees the whole user base, not just their own row'
);

select ok(
    (select prices_configured from public.admin_overview()) = false,
    'prices start unconfigured, and the dashboard says so rather than showing $0 MRR as fact'
);

-- ── money is never invented ───────────────────────────────────────────────

set local role postgres;
update public.product_prices set price_minor = 999 where product_id = 'smooooth.pro.monthly';
insert into public.subscriptions (
    user_id, product_id, original_transaction_id, latest_transaction_id,
    status, environment, expires_at
) values
    ('ad000002-b000-4000-8000-000000000002', 'smooooth.pro.monthly',
     'admin-test-prod-1', 'admin-test-prod-1', 'active', 'production', now() + interval '30 days'),
    ('ad000001-a000-4000-8000-000000000001', 'smooooth.pro.monthly',
     'admin-test-sandbox-1', 'admin-test-sandbox-1', 'active', 'sandbox', now() + interval '30 days');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ad000001-a000-4000-8000-000000000001","role":"authenticated"}';

select is(
    (select mrr_minor from public.admin_overview()),
    999::bigint,
    'a sandbox subscription is a test, and never counts as revenue'
);

select is(
    (select arr_minor from public.admin_overview()),
    (999 * 12)::bigint,
    'ARR is twelve months of MRR'
);

-- Every function must actually RUN for an admin. The first version of these
-- tests only proved that non-admins were refused, so a plain SQL error in
-- admin_growth_daily (timestamptz + integer) survived the whole suite and was
-- only caught by calling the API by hand. Refusing correctly is half the job.

select lives_ok(
    'select * from public.admin_overview()',
    'overview runs for an admin'
);
select lives_ok(
    'select * from public.admin_courses_by_region()',
    'courses-by-region runs for an admin'
);
select lives_ok(
    'select * from public.admin_top_courses(5)',
    'top-courses runs for an admin'
);
select lives_ok(
    'select * from public.admin_regions_by_activity(30)',
    'regions-by-activity runs for an admin'
);
select lives_ok(
    'select * from public.admin_revenue_by_product()',
    'revenue-by-product runs for an admin'
);
select lives_ok(
    'select * from public.admin_growth_daily(30)',
    'growth runs for an admin'
);
select lives_ok(
    'select * from public.admin_retention()',
    'retention runs for an admin'
);

select * from finish();
rollback;
