-- 0034: closing the search_path item the audit left Open.
--
-- Every SECURITY DEFINER function in this schema runs with
-- `search_path = ''` and fully-qualified names, for the standard reason: a
-- definer function resolves names with the CALLER's path unless it sets its
-- own, so an attacker who can create `public.courses` in a schema earlier on
-- that path gets the definer's privileges applied to their table.
--
-- Three exceptions existed. `courses_near` and `courses_in_region` were
-- introduced by the browse performance work with `search_path = public,
-- extensions`, and the `admin_*` analytics functions use `search_path =
-- public`.
--
-- NOT EXPLOITABLE, then or now, and the reason is worth stating because it
-- is the fact actually holding the line:
--
--   has_schema_privilege('authenticated', 'public', 'CREATE')  ->  false
--   has_schema_privilege('anon', 'public', 'CREATE')           ->  false
--
-- No client role can create anything in either schema, so there is nothing
-- to shadow. `0032_definer_search_path_test.sql` asserts that invariant
-- directly, because it is what the looser setting depends on and it was
-- depending on it silently.
--
-- The two browse functions are tightened here regardless. They are the ones
-- that decide who can see which course — the highest-consequence definers in
-- the schema — and they should not be relying on a grant somewhere else. The
-- bodies already qualify every name, so this changes nothing about what they
-- do; `0026_browse_matches_policy_test.sql` re-derives their answers from
-- the live RLS policy and would catch it if it did.
--
-- The admin_* functions are deliberately NOT touched. Eight of them, each
-- with long analytical bodies whose every reference would need qualifying,
-- to remove a risk that the invariant above already removes. That is churn
-- with a real chance of introducing a bug, against no change in exposure.

create or replace function public.courses_near(
    origin_lat double precision,
    origin_lon double precision,
    radius_meters double precision default 50000,
    max_results integer default 50
)
returns table (
    id uuid, name text, city text, region text, country text,
    distance_meters double precision, difficulty smallint, turn_count integer,
    benchmark_seconds integer, meters_away double precision, driver_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
    select c.id, c.name, c.city, c.region, c.country,
           c.distance_meters, c.difficulty, c.turn_count, c.benchmark_seconds,
           extensions.st_distance(c.start_point, origin) as meters_away,
           c.driver_count::bigint
      from public.courses c
      cross join lateral (
          select extensions.st_setsrid(
                     extensions.st_makepoint(origin_lon, origin_lat), 4326
                 )::extensions.geography
      ) as o(origin)
     where c.status = 'active'
       -- The RLS policy's own expression, applied here as a plain predicate
       -- so it is not a barrier. auth.uid() is read directly; no caller
       -- supplies an identity to this function.
       and (
           c.visibility = 'public'
           or c.creator_id = (select auth.uid())
           or (
               c.visibility = 'friends'
               and c.creator_id is not null
               and public.are_friends(c.creator_id, (select auth.uid()))
           )
       )
       and extensions.st_dwithin(
               c.start_point, origin, least(greatest(radius_meters, 100), 200000)
           )
     order by meters_away asc
     limit least(greatest(max_results, 1), 100);
$$;

create or replace function public.courses_in_region(
    p_country text,
    p_region text default null,
    p_city text default null,
    max_results integer default 50
)
returns table (
    id uuid, name text, city text, region text, country text,
    distance_meters double precision, difficulty smallint, turn_count integer,
    benchmark_seconds integer, driver_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
    select c.id, c.name, c.city, c.region, c.country,
           c.distance_meters, c.difficulty, c.turn_count, c.benchmark_seconds,
           c.driver_count::bigint
      from public.courses c
     where c.status = 'active'
       and (
           c.visibility = 'public'
           or c.creator_id = (select auth.uid())
           or (
               c.visibility = 'friends'
               and c.creator_id is not null
               and public.are_friends(c.creator_id, (select auth.uid()))
           )
       )
       and c.country = upper(p_country)
       and (p_region is null or c.region = p_region)
       and (p_city is null or c.city = p_city)
     order by c.driver_count desc, c.name asc
     limit least(greatest(max_results, 1), 100);
$$;

grant execute on function public.courses_near(
    double precision, double precision, double precision, integer
) to anon, authenticated, service_role;
grant execute on function public.courses_in_region(
    text, text, text, integer
) to anon, authenticated, service_role;
