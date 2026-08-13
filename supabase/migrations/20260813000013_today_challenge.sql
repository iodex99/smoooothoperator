-- 0013: Today's Challenge — dynamic, location-based daily challenge
-- assignment (directive 2026-08-13). No per-city hand-authoring: the
-- backend finds eligible courses near the user, ranks them, and assigns
-- the best one for the user's LOCAL date. One row per (user, local_date)
-- exists only for users who actually open the app that day — it is the
-- cache, the "last shown" rotation signal, and the debug trail in one.

-- ── Assignment cache ───────────────────────────────────────────────────────

create table public.challenge_assignments (
    user_id uuid not null references public.profiles (id) on delete cascade,
    local_date date not null,
    -- Challenge format key (spec: SMOOTH_SPRINT first; registry lives in
    -- the edge function so new formats need no migration).
    format text not null default 'SMOOTH_SPRINT',
    course_id uuid not null references public.courses (id) on delete cascade,
    -- Search radius that produced the selection (km); null = country mode.
    radius_km integer,
    -- Ranking snapshot: candidates, scores, and why this course won.
    -- Debug/admin surface (spec §23) — never parsed by clients.
    reason jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (user_id, local_date)
);

comment on table public.challenge_assignments is
    'Per-user daily challenge selection. Cache + rotation history + debug trail; rows exist only for users who requested a challenge that day.';

create index challenge_assignments_course_idx
    on public.challenge_assignments (user_id, course_id, created_at desc);

alter table public.challenge_assignments enable row level security;

-- Owners may read their assignment (the response is normally served by the
-- edge function, but honest debugging beats opacity). All writes go through
-- the service role — clients can never choose their own challenge.
grant select on public.challenge_assignments to authenticated;
grant all on public.challenge_assignments to service_role;

create policy "users see own challenge assignments"
    on public.challenge_assignments
    for select
    using (user_id = (select auth.uid()));

create trigger challenge_assignments_set_updated_at
    before update on public.challenge_assignments
    for each row
    execute function public.set_updated_at();

-- ── Candidate search ───────────────────────────────────────────────────────
-- One call returns every ranking signal for eligible courses near a point,
-- so the edge function does a single round-trip per radius step. SECURITY
-- DEFINER: visibility rules are re-implemented here (public+active, own
-- courses, friends-visibility via are_friends) — keep in lockstep with the
-- courses RLS policy in migration 0008.

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
          where r.course_id = c.id and r.user_id = uid),
        (select extract(day from now() - max(a.created_at))::int
           from public.challenge_assignments a
          where a.course_id = c.id and a.user_id = uid),
        fb.score,
        fb.username,
        fb.days_ago,
        (select count(distinct r.user_id)::int
           from public.runs r
          where r.course_id = c.id and r.created_at >= day_start),
        (select le.score
           from public.leaderboard_entries le
          where le.course_id = c.id and le.user_id = uid)
    from public.courses c
    left join lateral (
        select le.score,
               p.username,
               extract(day from now() - le.updated_at)::int as days_ago
        from public.leaderboard_entries le
        join public.profiles p on p.id = le.user_id
        where le.course_id = c.id
          and le.user_id <> uid
          and public.are_friends(uid, le.user_id)
        order by le.score desc
        limit 1
    ) fb on true
    where c.status = 'active'
      and (
          c.visibility = 'public'
          or c.creator_id = uid
          or (
              c.visibility = 'friends'
              and c.creator_id is not null
              and public.are_friends(uid, c.creator_id)
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

revoke all on function public.challenge_candidates from public, anon;
grant execute on function public.challenge_candidates(
    uuid, double precision, double precision, double precision, timestamptz, integer
) to authenticated, service_role;

-- ── Drive-ready route payload ──────────────────────────────────────────────
-- GeoJSON polyline + ordered gates for one course, with the same visibility
-- rules. Serves today-challenge now and the course-detail server fetch
-- later; clients never parse WKB.

create or replace function public.course_route(
    uid uuid,
    cid uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
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
          or c.creator_id = uid
          or (
              c.visibility = 'friends'
              and c.creator_id is not null
              and public.are_friends(uid, c.creator_id)
          )
      );
$$;

revoke all on function public.course_route from public, anon;
grant execute on function public.course_route(uuid, uuid)
    to authenticated, service_role;
