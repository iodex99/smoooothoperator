-- A SECURITY DEFINER function resolves names with the CALLER's search_path
-- unless it sets its own. If a caller can create `courses` in a schema that
-- sits earlier on that path, the definer's privileges get applied to the
-- caller's table.
--
-- Most functions here set `search_path = ''` and qualify everything. The
-- `admin_*` analytics functions set `search_path = public`, which is safe
-- ONLY because of one fact that was, until this file, holding the line
-- silently:
--
--   no client role can create anything in `public` or `extensions`.
--
-- That is the invariant. It is asserted directly, because a defence nobody
-- has written down is a defence somebody can remove without noticing they
-- removed anything.

begin;
select plan(6);

-- ── the fact everything else rests on ─────────────────────────────────────

select ok(
    not has_schema_privilege('authenticated', 'public', 'CREATE'),
    'a signed-in driver cannot create objects in public — this is what makes '
    'a definer function with a non-empty search_path safe'
);

select ok(
    not has_schema_privilege('anon', 'public', 'CREATE'),
    'nor can an anonymous caller'
);

select ok(
    not has_schema_privilege('authenticated', 'extensions', 'CREATE')
    and not has_schema_privilege('anon', 'extensions', 'CREATE'),
    'and neither can create in extensions, where the PostGIS functions live'
);

-- ── the functions that decide who sees what do not rely on it ─────────────
--
-- These two bypass RLS and re-apply the visibility rules themselves, which
-- makes them the highest-consequence definers in the schema. They set an
-- empty path and qualify every name, so they hold even if the invariant
-- above is ever weakened.

select is(
    (select coalesce(string_agg(p.proname, ', ' order by p.proname), '')
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('courses_near', 'courses_in_region')
        -- Postgres stores an empty path as the literal `search_path=""`,
        -- quotes included — comparing against `search_path=` matches nothing
        -- and quietly passes.
        and not ('search_path=""' = any (coalesce(p.proconfig, array[]::text[])))),
    '',
    'the browse functions run with an empty search_path — they decide who '
    'can see which course and should not depend on a grant elsewhere'
);

-- ── every definer function sets SOME search_path ──────────────────────────
--
-- Setting none at all is the actually dangerous case: the function then uses
-- whatever the caller's session has, which the caller controls completely.

select is(
    (select coalesce(string_agg(p.proname, ', ' order by p.proname), '')
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prosecdef
        and p.proconfig is null),
    '',
    'every SECURITY DEFINER function pins a search_path — one that sets none '
    'uses whatever the caller''s session says, which the caller controls'
);

select cmp_ok(
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prosecdef), '>=', 20::bigint,
    'and the enumeration found the functions — a query matching nothing '
    'satisfies every assertion made about it'
);

select * from finish();
rollback;
