-- 0025: make browsing the catalog scale.
--
-- Measured on this database, seeded to 50,000 courses:
--
--   courses_near      150 ms
--   courses_in_region 151 ms
--
-- Those are the two queries behind Explore — the screen a driver opens
-- first, every session. 150 ms of pure database time before any network,
-- and both were O(catalog size), so the numbers get worse exactly as the
-- product succeeds.
--
-- TWO CAUSES, both invisible at the 397 courses the catalog ships with:
--
-- 1. NO SPATIAL INDEX ON THE COLUMN ACTUALLY QUERIED. The GiST index is on
--    `geometry`, the LineString. `courses_near` filters on `start_point`,
--    which had no index at all, so every Explore open sequentially scanned
--    the catalog computing a geography distance per row.
--
-- 2. THE DRIVER COUNT WAS A CORRELATED SUBQUERY. Ordering by it forced a
--    count over `leaderboard_entries` for EVERY matching course before the
--    sort could run, so `limit 50` saved nothing — the work was already
--    done. Denormalised onto the course and maintained by trigger.

-- ── 1. index the column the query filters on ──────────────────────────────

create index if not exists courses_start_point_idx
    on public.courses using gist (start_point)
    where status = 'active';

-- ── 2. the driver count, kept up to date rather than recomputed ───────────

alter table public.courses
    add column if not exists driver_count integer not null default 0;

-- A count that drifts is worse than a slow one: it is shown to drivers as
-- "how many people have driven this". Maintained on every write to the
-- leaderboard, which is the only place it can change.
create or replace function public.sync_course_driver_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if tg_op = 'DELETE' then
        update public.courses
           set driver_count = greatest(0, driver_count - 1)
         where id = old.course_id;
        return old;
    elsif tg_op = 'INSERT' then
        update public.courses
           set driver_count = driver_count + 1
         where id = new.course_id;
        return new;
    elsif tg_op = 'UPDATE' and new.course_id is distinct from old.course_id then
        update public.courses set driver_count = greatest(0, driver_count - 1)
         where id = old.course_id;
        update public.courses set driver_count = driver_count + 1
         where id = new.course_id;
        return new;
    end if;
    return new;
end;
$$;

drop trigger if exists leaderboard_entries_sync_driver_count on public.leaderboard_entries;
create trigger leaderboard_entries_sync_driver_count
    after insert or update or delete on public.leaderboard_entries
    for each row execute function public.sync_course_driver_count();

-- Backfill from the truth, so the denormalised value starts correct rather
-- than starting at zero and only becoming right for future runs.
update public.courses c
   set driver_count = coalesce(
       (select count(*) from public.leaderboard_entries e where e.course_id = c.id), 0
   );

-- `name` is in the index because it is the tie-break in the ORDER BY, and
-- without it the scan reads every matching row to sort within equal driver
-- counts — which is all of them on a young catalog, where nothing has been
-- driven yet. Measured: 50,000 rows read to return 50.
create index if not exists courses_popular_idx
    on public.courses (country, driver_count desc, name)
    where status = 'active';

-- ── 3. the reason the index was not being used at all ─────────────────────
--
-- Measured again with RLS actually applied (the earlier numbers were taken
-- as superuser, which bypasses it):
--
--   courses_near, RLS off  →  33 ms, Index Scan
--   courses_near, RLS on   → 157 ms, SEQ SCAN, "Rows Removed by Filter: 50404"
--
-- The whole catalog, scanned, for every driver, on every Explore open.
--
-- MECHANISM: row-level security makes the table a security barrier. A qual
-- from the caller may only be pushed below the policy check if it is
-- LEAKPROOF, because a non-leakproof function could reveal the contents of
-- a row the policy would have hidden — through an error message, say. None
-- of the PostGIS predicates are leakproof:
--
--   select proname, proleakproof from pg_proc where proname = 'st_dwithin';
--   →  st_dwithin | f
--
-- So `st_dwithin` cannot become an index condition, the GiST index is
-- unusable, and the planner has nothing left but a sequential scan. Adding
-- the index in step 1 was necessary and, on its own, useless.
--
-- FIX: run the browse as SECURITY DEFINER and apply the visibility rules
-- IN the function, where they are ordinary predicates rather than a
-- barrier. The index works again and the rules are unchanged.
--
-- This is the pattern that leaked data once already in this project, so the
-- shape matters:
--   * the function takes NO user id. It reads auth.uid() itself, exactly
--     like `is_admin()`. There is nothing for a caller to spoof.
--   * the visibility test is the SAME expression as the RLS policy, not a
--     re-derivation, so the two cannot drift into disagreeing.
--   * pgTAP asserts a private course belonging to someone else is still
--     invisible through it — that test predates this change and still runs.

-- ── the browse queries, using both ────────────────────────────────────────

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
set search_path = public, extensions
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
set search_path = public, extensions
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
