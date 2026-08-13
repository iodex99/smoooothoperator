-- 0014: production-readiness audit hardening (2026-08-13).
--
-- Three defects found by the security/data review:
--   1. `runs.status` was client-writable with no transition guard, so a
--      client could PATCH a run to 'scored' (state forgery — the actual
--      score columns were already protected, but any UI keyed on status
--      would display a fabricated finished run).
--   2. `course_checkpoints` RLS was missing the `friends` branch that
--      `courses` has, so a friends-visibility course was visible but had
--      no gates: listed, and undriveable.
--   3. `telemetry.storage_path` was unvalidated, and score-run interpolates
--      it into a service-role storage URL. The edge function now checks it;
--      this adds the same rule at the database boundary.

-- ── 1. Clients may only make the ONE status transition they own ───────────
-- The upload flow legitimately moves a run 'recording' -> 'uploaded' (that
-- transition is what enqueues the scoring job). Everything after that is the
-- pipeline's: 'processing' and 'scored' are server-owned states, and a
-- client that could set them could display a fabricated finished run.
create or replace function public.guard_run_status_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    -- Only client roles are restricted. PostgREST executes client requests as
    -- `authenticated`/`anon`; the scoring pipeline runs as service_role (and
    -- migrations/tests as the owner), which the pipeline needs unrestricted.
    -- Keying on the database role rather than auth.uid() matters: JWT claims
    -- can outlive a `reset role` inside one transaction.
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

create trigger runs_guard_status
    before update on public.runs
    for each row
    execute function public.guard_run_status_transition();

comment on column public.runs.status is
    'Clients may only move recording -> uploaded; processing/scored are server-owned (audit 2026-08-13).';

-- ── 2. Checkpoints inherit the FULL course visibility rule ────────────────
drop policy if exists "checkpoints follow course visibility" on public.course_checkpoints;

create policy "checkpoints follow course visibility"
    on public.course_checkpoints
    for select
    using (
        exists (
            select 1 from public.courses c
            where c.id = course_id
              and (
                  (c.visibility = 'public' and c.status = 'active')
                  or c.creator_id = (select auth.uid())
                  or (
                      c.visibility = 'friends'
                      and c.status = 'active'
                      and c.creator_id is not null
                      and public.are_friends((select auth.uid()), c.creator_id)
                  )
              )
        )
    );

-- ── 3. Telemetry paths must live under the run owner's own prefix ─────────
-- Storage policy already confines UPLOADS to `<user-uuid>/...`; this stops a
-- client from registering an envelope pointing anywhere else, which the
-- service-role scorer would then have fetched with RLS bypassed.
create or replace function public.validate_telemetry_path()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    owner uuid;
begin
    select r.user_id into owner from public.runs r where r.id = new.run_id;
    if owner is null then
        raise exception 'run not found' using errcode = '23503';
    end if;
    if new.storage_path !~ ('^' || owner::text || '/[A-Za-z0-9._-]+$') then
        raise exception 'telemetry storage_path must live under the run owner''s prefix'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

create trigger telemetry_validate_path
    before insert or update on public.telemetry
    for each row
    execute function public.validate_telemetry_path();

-- ── 4. Participant counts are VERIFIED runs only ──────────────────────────
-- `challenge_candidates` counted any run row, and clients can insert run
-- rows freely — so "participants today" was inflatable. Today's Challenge
-- promises real numbers (directive §§9, 12); make it true.
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
        -- Verified runs only: a client can insert run rows, so counting all
        -- of them let anyone inflate the number shown to other drivers.
        (select count(distinct r.user_id)::int
           from public.runs r
          where r.course_id = c.id
            and r.created_at >= day_start
            and r.verification = 'verified'),
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

-- ── 5. Account deletion (App Store 5.1.1(v), spec §62) ────────────────────
-- Erases the caller's account. Everything else cascades from auth.users:
-- profile, runs, telemetry envelopes, ghosts, friendships, assignments.
-- Raw telemetry blobs are removed by the caller's storage delete policy
-- (added below) before this runs.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := (select auth.uid());
begin
    if me is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;
    delete from auth.users where id = me;
end;
$$;

revoke all on function public.delete_my_account from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- Owners may delete their own raw telemetry: without this, blobs survive
-- account deletion with no index back to them (the telemetry row cascades
-- away), leaving the most sensitive data unerasable.
create policy "owners delete own telemetry blobs"
    on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'telemetry'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );
