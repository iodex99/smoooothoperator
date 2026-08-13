-- 0016: SECURITY DEFINER functions must not trust `current_user` or a
-- caller-supplied id. Adversarial review 2026-08-13, round 4.
--
-- Root cause shared by everything here: inside a SECURITY DEFINER function
-- `current_user` is the function OWNER, not the caller, and any `uid`
-- parameter is whatever the caller typed. Two shipped controls were built
-- on those assumptions and were therefore inert or exploitable.

-- ── 1. The run-status guard never fired ───────────────────────────────────
-- `guard_run_status_transition` (migration 0014) began with
--   if current_user not in ('authenticated','anon') then return new;
-- but as SECURITY DEFINER `current_user` is always `postgres`, so it
-- short-circuited on EVERY call and no transition was ever checked. A
-- client could still PATCH a run to any status — verified live, HTTP 204.
--
-- That also defeated the paid daily allowance: score-run counts runs with
-- status='scored', so an attacker flipped their scored runs back to
-- 'uploaded' to reset the meter while KEEPING their leaderboard entries.
--
-- Running as INVOKER makes current_user the caller's role, which is what
-- the check always assumed.
create or replace function public.guard_run_status_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    -- Now genuinely the caller's role: PostgREST runs client requests as
    -- `authenticated`/`anon`; the pipeline runs as service_role.
    if current_user not in ('authenticated', 'anon') then
        return new;
    end if;
    if new.status is distinct from old.status
       and not (old.status = 'recording' and new.status = 'uploaded')
       and not (old.status = 'uploaded' and new.status = 'uploaded')
    then
        raise exception 'run status % -> % is owned by the scoring pipeline',
            old.status, new.status
            using errcode = '42501';
    end if;
    return new;
end;
$$;

-- Belt and braces: the allowance must not depend on a client-writable
-- column at all. `verification` has no client grant, so it cannot be
-- rewritten even if a status guard is ever bypassed again.
comment on column public.runs.verification is
    'Server-authoritative verdict. The daily free-tier count is keyed on THIS, not on status, because status is client-writable within its allowed transition (audit round 4).';

-- ── 2. Candidate search leaked any user's drive history ───────────────────
-- `challenge_candidates` trusted its `uid` argument, so any authenticated
-- user could pass a victim's id and sweep coordinates to learn WHICH
-- courses that person has driven and HOW RECENTLY — bypassing runs RLS —
-- plus their friend graph and friends' scores.
--
-- The client never calls this directly (it calls the today-challenge
-- function, which runs as service role), so the client grant simply goes.
revoke execute on function public.challenge_candidates(
    uuid, double precision, double precision, double precision, timestamptz, integer
) from authenticated;

-- And defence in depth: an authenticated caller may only ever ask about
-- themselves. auth.uid() is NULL for the service role, which is what lets
-- the edge function keep asking on a user's behalf.
create or replace function public.challenge_candidates(
    uid uuid,
    origin_lat double precision,
    origin_lon double precision,
    radius_meters double precision,
    day_start timestamptz,
    max_results integer default 25
)
returns table (
    course_id uuid,
    name text,
    proximity_km double precision,
    distance_meters double precision,
    estimated_duration_seconds integer,
    difficulty smallint,
    turn_count integer,
    benchmark_seconds integer,
    verified_drivers integer,
    days_since_user_drove integer,
    days_since_assigned integer,
    friend_best_score integer,
    friend_username text,
    friend_days_ago integer,
    participants_today integer,
    your_best integer
)
language sql
security definer
set search_path = ''
as $$
    with subject as (
        -- A client can only ever be themselves; service_role (auth.uid() is
        -- null) keeps acting on the requested user's behalf.
        select coalesce((select auth.uid()), uid) as id
    )
    select
        c.id,
        c.name,
        extensions.st_distance(
            c.start_point,
            extensions.st_setsrid(
                extensions.st_makepoint(origin_lon, origin_lat), 4326
            )::extensions.geography
        ) / 1000.0,
        c.distance_meters,
        c.estimated_duration_seconds,
        c.difficulty,
        c.turn_count,
        c.benchmark_seconds,
        (select count(distinct le.user_id)::int
           from public.leaderboard_entries le
          where le.course_id = c.id),
        (select extract(day from now() - max(r.created_at))::int
           from public.runs r
          where r.course_id = c.id and r.user_id = (select id from subject)),
        (select extract(day from now() - max(a.created_at))::int
           from public.challenge_assignments a
          where a.course_id = c.id and a.user_id = (select id from subject)),
        fb.score,
        fb.username,
        fb.days_ago,
        (select count(distinct r.user_id)::int
           from public.runs r
          where r.course_id = c.id
            and r.created_at >= day_start
            and r.verification = 'verified'),
        (select le.score
           from public.leaderboard_entries le
          where le.course_id = c.id and le.user_id = (select id from subject))
    from public.courses c
    left join lateral (
        select le.score,
               p.username,
               extract(day from now() - le.updated_at)::int as days_ago
        from public.leaderboard_entries le
        join public.profiles p on p.id = le.user_id
        where le.course_id = c.id
          and le.user_id <> (select id from subject)
          and public.are_friends((select id from subject), le.user_id)
        order by le.score desc
        limit 1
    ) fb on true
    where c.status = 'active'
      and (
          c.visibility = 'public'
          or c.creator_id = (select id from subject)
          or (
              c.visibility = 'friends'
              and c.creator_id is not null
              and public.are_friends((select id from subject), c.creator_id)
          )
      )
      and extensions.st_dwithin(
          c.start_point,
          extensions.st_setsrid(
              extensions.st_makepoint(origin_lon, origin_lat), 4326
          )::extensions.geography,
          radius_meters
      )
    order by 3 asc
    limit max_results;
$$;

revoke all on function public.challenge_candidates(
    uuid, double precision, double precision, double precision, timestamptz, integer
) from public, anon, authenticated;
grant execute on function public.challenge_candidates(
    uuid, double precision, double precision, double precision, timestamptz, integer
) to service_role;

-- ── 3. course_route had the same flaw ─────────────────────────────────────
-- Here the client legitimately calls it, so the fix is to ignore the passed
-- id for authenticated callers rather than revoke.
create or replace function public.course_route(
    uid uuid,
    cid uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
    with subject as (
        select coalesce((select auth.uid()), uid) as id
    )
    select jsonb_build_object(
        'courseId', c.id,
        'polyline', extensions.st_asgeojson(c.geometry)::jsonb -> 'coordinates',
        'gates', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'sequence', k.sequence,
                'latitude', extensions.st_y(k.center::extensions.geometry),
                'longitude', extensions.st_x(k.center::extensions.geometry),
                'radiusMeters', k.radius_meters
            ) order by k.sequence), '[]'::jsonb)
            from public.course_checkpoints k
            where k.course_id = c.id
        )
    )
    from public.courses c
    where c.id = cid
      and c.status = 'active'
      and (
          c.visibility = 'public'
          or c.creator_id = (select id from subject)
          or (
              c.visibility = 'friends'
              and c.creator_id is not null
              and public.are_friends((select id from subject), c.creator_id)
          )
      );
$$;

revoke all on function public.course_route(uuid, uuid) from public, anon;
grant execute on function public.course_route(uuid, uuid)
    to authenticated, service_role;

-- ── 4. Entitlement status was probeable for any user ──────────────────────
create or replace function public.has_active_pro(p_user uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
    select exists (
        select 1 from public.subscriptions s
        where s.user_id = coalesce((select auth.uid()), p_user)
          and s.status in ('active', 'in_grace_period')
          and s.expires_at is not null
          and s.expires_at > now()
          and s.environment = 'production'
    );
$$;

grant execute on function public.has_active_pro(uuid) to authenticated, service_role;

-- ── 5. Unbounded public profile text ──────────────────────────────────────
-- `profiles` is world-readable, and display_name/region/city had no length
-- limit: a 500 KB display_name was accepted and served to anon, riding into
-- every leaderboard and challenge payload that embeds a profile.
alter table public.profiles
    add constraint profiles_display_name_length
        check (char_length(display_name) <= 40),
    add constraint profiles_region_length
        check (region is null or char_length(region) <= 60),
    add constraint profiles_city_length
        check (city is null or char_length(city) <= 60);

-- ── 6. A per-user ceiling on run rows ─────────────────────────────────────
-- No quota existed anywhere: 500 runs inserted in 37 ms in testing, each of
-- which can enqueue scoring work. This is a blunt abuse ceiling, far above
-- any real driver (the free tier is 3/day, Pro is unlimited but human).
create or replace function public.limit_runs_per_day()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    todays integer;
begin
    if current_user not in ('authenticated', 'anon') then
        return new;
    end if;
    select count(*) into todays
      from public.runs r
     where r.user_id = new.user_id
       and r.created_at >= date_trunc('day', now());
    if todays >= 100 then
        raise exception 'too many runs today'
            using errcode = '54000';
    end if;
    return new;
end;
$$;

create trigger runs_daily_ceiling
    before insert on public.runs
    for each row
    execute function public.limit_runs_per_day();
