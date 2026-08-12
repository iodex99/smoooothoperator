-- 0010: scoring infrastructure — telemetry bucket, pipeline geometry RPC,
-- atomic result application, stale-job recovery (spec §46 flow).

-- ── Private telemetry bucket ──────────────────────────────────────────────
-- Raw telemetry blobs (gzip JSON) live here; path convention:
-- telemetry/<user_id>/<run_id>.json.gz — first folder = owner uuid.
insert into storage.buckets (id, name, public)
values ('telemetry', 'telemetry', false)
on conflict (id) do nothing;

-- Owners may upload into their own folder and read their own objects.
-- Nobody else (spec §66); the service role bypasses RLS.
create policy "owners upload own telemetry"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'telemetry'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

create policy "owners read own telemetry"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'telemetry'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

-- ── Course geometry for the pipeline ──────────────────────────────────────
-- The server scorer needs the course polyline + gates + benchmark as plain
-- JSON. Coordinates are returned [lat, lon] (pipeline convention; note
-- GeoJSON itself is [lon, lat] — converted here, in one place).
create or replace function public.course_pipeline_geometry(course uuid)
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
    select jsonb_build_object(
        'polyline', (
            select jsonb_agg(jsonb_build_array(
                (point ->> 1)::double precision,   -- lat
                (point ->> 0)::double precision    -- lon
            ) order by ordinality)
            from jsonb_array_elements(
                (extensions.st_asgeojson(c.geometry)::jsonb) -> 'coordinates'
            ) with ordinality as coords(point, ordinality)
        ),
        'gates', (
            select coalesce(jsonb_agg(jsonb_build_array(
                cp.sequence,
                extensions.st_y(cp.center::extensions.geometry),
                extensions.st_x(cp.center::extensions.geometry),
                cp.radius_meters
            ) order by cp.sequence), '[]'::jsonb)
            from public.course_checkpoints cp
            where cp.course_id = c.id
        ),
        'benchmarkSeconds', c.benchmark_seconds,
        'distanceMeters', c.distance_meters
    )
    from public.courses c
    where c.id = course;
$$;

grant execute on function public.course_pipeline_geometry(uuid) to service_role;

-- ── Atomic result application ─────────────────────────────────────────────
-- The edge function computes; this RPC applies everything in ONE
-- transaction: authoritative run fields, best-entry leaderboard upsert
-- (verified + finished runs only), ghost creation, job completion.
create or replace function public.apply_run_result(
    p_run_id uuid,
    p_verification text,
    p_score integer,
    p_pace_bps integer,
    p_smoothness_bps integer,
    p_control_bps integer,
    p_compliance_bps integer,
    p_confidence integer,
    p_scoring_version text,
    p_integrity_flags jsonb,
    p_duration_seconds double precision,
    p_finished boolean,
    p_ghost_trajectory jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_run public.runs%rowtype;
    v_existing_score integer;
begin
    select * into v_run from public.runs where id = p_run_id for update;
    if not found then
        raise exception 'run % not found', p_run_id;
    end if;

    update public.runs
    set verification = p_verification,
        score = p_score,
        pace_bps = p_pace_bps,
        smoothness_bps = p_smoothness_bps,
        control_bps = p_control_bps,
        compliance_bps = p_compliance_bps,
        confidence_score = p_confidence,
        scoring_version = p_scoring_version,
        integrity_flags = p_integrity_flags,
        status = 'scored'
    where id = p_run_id;

    -- Only verified, finished runs compete (spec §44) — and only
    -- improvements displace an existing best entry.
    if p_verification = 'verified' and p_finished then
        select score into v_existing_score
        from public.leaderboard_entries
        where course_id = v_run.course_id and user_id = v_run.user_id;

        if v_existing_score is null or p_score > v_existing_score then
            insert into public.leaderboard_entries
                (course_id, user_id, run_id, score, duration_seconds, smoothness_bps)
            values
                (v_run.course_id, v_run.user_id, p_run_id, p_score,
                 p_duration_seconds, p_smoothness_bps)
            on conflict (course_id, user_id) do update
            set run_id = excluded.run_id,
                score = excluded.score,
                duration_seconds = excluded.duration_seconds,
                smoothness_bps = excluded.smoothness_bps;
        end if;

        if p_ghost_trajectory is not null then
            insert into public.ghosts
                (run_id, course_id, user_id, trajectory, score, duration_seconds)
            values
                (p_run_id, v_run.course_id, v_run.user_id,
                 p_ghost_trajectory, p_score, p_duration_seconds)
            on conflict (run_id) do nothing;
        end if;
    end if;

    update public.scoring_jobs
    set status = 'done', last_error = null
    where run_id = p_run_id;
end;
$$;

grant execute on function public.apply_run_result to service_role;

-- ── Stale-job recovery ────────────────────────────────────────────────────
-- Jobs stuck in 'processing' (crashed invocation) return to 'pending' after
-- 5 minutes; a cloud deployment additionally schedules re-invocation of
-- score-run via pg_net (URL + key live in Vault, configured at deploy —
-- see docs/DATABASE.md).
create or replace function public.recover_stale_scoring_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    recovered integer;
begin
    update public.scoring_jobs
    set status = 'pending'
    where status = 'processing'
      and updated_at < now() - interval '5 minutes';
    get diagnostics recovered = row_count;
    return recovered;
end;
$$;

grant execute on function public.recover_stale_scoring_jobs to service_role;

select cron.schedule(
    'recover-stale-scoring-jobs',
    '* * * * *',
    $$select public.recover_stale_scoring_jobs()$$
);
