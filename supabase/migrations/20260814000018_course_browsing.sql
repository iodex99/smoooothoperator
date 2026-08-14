-- 0018: browsing the catalog (spec §§25, 63).
--
-- Explore has shipped since day one with no list query behind it: the tab
-- rendered a single bundled demo course and a sentence promising that 397
-- real ones "load here with your account". They never did, because nothing
-- ever asked for them.
--
-- Two entry points, because a driver arrives in one of two states:
--   * location granted  -> `courses_near` sorts by real distance from them
--   * no location       -> `courses_in_region` falls back to country/region
--
-- SECURITY: both are SECURITY INVOKER, so the caller's RLS on public.courses
-- decides visibility. That is deliberate. `challenge_candidates` was written
-- as DEFINER and had to be fixed later when it turned out to trust a
-- caller-supplied user id; a browse query has no reason to escalate at all.

-- Distance from the driver is the whole point of "nearby", so the sort key
-- has to be a real geography distance, not a bounding box.
create or replace function public.courses_near(
    origin_lat double precision,
    origin_lon double precision,
    radius_meters double precision default 50000,
    max_results integer default 50
)
returns table (
    id uuid,
    name text,
    city text,
    region text,
    country text,
    distance_meters double precision,
    difficulty smallint,
    turn_count integer,
    benchmark_seconds integer,
    meters_away double precision,
    driver_count bigint
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
    select c.id,
           c.name,
           c.city,
           c.region,
           c.country,
           c.distance_meters,
           c.difficulty,
           c.turn_count,
           c.benchmark_seconds,
           extensions.st_distance(c.start_point, origin) as meters_away,
           coalesce(le.drivers, 0) as driver_count
      from public.courses c
      cross join lateral (
          select extensions.st_setsrid(
                     extensions.st_makepoint(origin_lon, origin_lat), 4326
                 )::extensions.geography
      ) as o(origin)
      left join lateral (
          select count(*) as drivers
            from public.leaderboard_entries e
           where e.course_id = c.id
      ) le on true
     where c.status = 'active'
       -- Bounded input: a caller asking for a 40 000 km radius is asking for
       -- the whole table, and an unbounded limit is a denial-of-service.
       and extensions.st_dwithin(
               c.start_point, origin, least(greatest(radius_meters, 100), 200000)
           )
     order by meters_away asc
     limit least(greatest(max_results, 1), 100);
$$;

-- The no-location fallback. Country is required (an unfiltered browse of the
-- whole catalog is not a feature anyone asked for and is a slow query);
-- region and city narrow it further when the caller knows them.
create or replace function public.courses_in_region(
    p_country text,
    p_region text default null,
    p_city text default null,
    max_results integer default 50
)
returns table (
    id uuid,
    name text,
    city text,
    region text,
    country text,
    distance_meters double precision,
    difficulty smallint,
    turn_count integer,
    benchmark_seconds integer,
    driver_count bigint
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
    select c.id,
           c.name,
           c.city,
           c.region,
           c.country,
           c.distance_meters,
           c.difficulty,
           c.turn_count,
           c.benchmark_seconds,
           coalesce(le.drivers, 0) as driver_count
      from public.courses c
      left join lateral (
          select count(*) as drivers
            from public.leaderboard_entries e
           where e.course_id = c.id
      ) le on true
     where c.status = 'active'
       and c.country = upper(p_country)
       and (p_region is null or c.region = p_region)
       and (p_city is null or c.city = p_city)
     order by coalesce(le.drivers, 0) desc, c.name asc
     limit least(greatest(max_results, 1), 100);
$$;

-- Which countries actually have courses, so the picker can offer real
-- options instead of a list of 195 countries that are mostly empty.
create or replace function public.course_regions()
returns table (country text, region text, course_count bigint)
language sql
stable
security invoker
set search_path = public, extensions
as $$
    select c.country, c.region, count(*) as course_count
      from public.courses c
     where c.status = 'active'
       and c.country is not null
     group by c.country, c.region
     order by count(*) desc, c.country, c.region;
$$;

-- Anonymous browsing is intentional: a shared course link has to open for
-- someone who has not installed the app yet. RLS still limits every row to
-- the public/active ones.
grant execute on function public.courses_near(
    double precision, double precision, double precision, integer
) to anon, authenticated, service_role;
grant execute on function public.courses_in_region(
    text, text, text, integer
) to anon, authenticated, service_role;
grant execute on function public.course_regions() to anon, authenticated, service_role;

-- The region fallback filters on country/region/city; without this it is a
-- sequential scan of the whole catalog on every Explore open.
create index if not exists courses_region_browse_idx
    on public.courses (country, region, city)
    where status = 'active';
