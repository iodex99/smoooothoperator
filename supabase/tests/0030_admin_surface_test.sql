-- The operator console reads the whole business: every driver, every run,
-- revenue, retention. `0017_admin_analytics_test.sql` asserts three of the
-- eight analytics functions refuse a non-admin. All eight are NAMED in that
-- file, which is what made it look complete.
--
-- This one does not name any of them. It enumerates `admin_*` from the
-- catalog and requires every one to refuse, so a function added later is
-- covered the moment it exists rather than the moment somebody remembers to
-- add a case. That is the difference between a list and a guard.
--
-- It also pins the two shapes that make the gate meaningful at all:
-- `is_admin()` must take no arguments, and the admins table must be
-- unreachable from the API.

begin;
select plan(5);

insert into auth.users (id, email) values
    ('ad000001-0000-4000-8000-000000000001', 'nosy@test.local');

set local role authenticated;
set local request.jwt.claims = '{"sub":"ad000001-0000-4000-8000-000000000001","role":"authenticated"}';

-- ── every admin function, whatever it is called ───────────────────────────

create temp table admin_probe (name text, reachable boolean);

do $$
declare
    fn record;
begin
    for fn in
        select p.proname
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname like 'admin\_%'
         order by p.proname
    loop
        begin
            -- Called with no arguments; every admin function either takes
            -- none or defaults all of them, which is itself part of the
            -- contract — one that REQUIRED an argument would be one that
            -- could be pointed at somebody.
            execute format('select public.%I()', fn.proname);
            insert into admin_probe values (fn.proname, true);
        exception
            when others then
                insert into admin_probe values (fn.proname, false);
        end;
    end loop;
end $$;

-- A behavioural check, deliberately: it does not care HOW a function is
-- protected, only that it is. `0017` makes the same assertion by grepping
-- for `require_admin` in the source and has to exclude `admin_mrr_minor` BY
-- NAME, because that one is protected by its grant instead. An allow-list is
-- where the next real one hides; this needs no exception.
select is(
    (select coalesce(string_agg(name, ', ' order by name), '')
       from admin_probe where reachable),
    '',
    'every admin_* function in the catalog refuses a non-admin — enumerated, '
    'not listed, so one added later is covered the moment it exists'
);

select cmp_ok(
    (select count(*) from admin_probe), '>=', 8::bigint,
    'and the enumeration actually found the functions — a probe that matches '
    'nothing passes every assertion about it'
);

-- ── the gate cannot be pointed at somebody else ───────────────────────────

select is(
    (select count(*)::int from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('is_admin', 'require_admin')
        and p.pronargs > 0),
    0,
    'is_admin() and require_admin() take no arguments — a gate you can hand '
    'an id to is a gate that answers about somebody else'
);

-- ── operator status is not something the API can read or grant ────────────

select throws_ok(
    'select * from public.admins',
    null,
    null,
    'the admins table is not readable through the API — who is an operator '
    'is not public, and there is deliberately no path to grant it from a client'
);

select throws_ok(
    $$ insert into public.admins (user_id)
       values ('ad000001-0000-4000-8000-000000000001') $$,
    null,
    null,
    'and nobody can make themselves one'
);

select * from finish();
rollback;
