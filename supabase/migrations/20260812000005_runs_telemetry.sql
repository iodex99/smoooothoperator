-- 0005: runs + telemetry envelope + scoring job queue (spec §§44-46, 60).
--
-- Trust boundary: clients may create their own runs and record a PROVISIONAL
-- client_score, but every authoritative column (score, sub-scores, verdict,
-- confidence, scoring_version, integrity findings) has NO client grant —
-- only the service role (score-run edge function) writes results. A client
-- cannot submit score=99999 (spec §45).

create table public.runs (
    id uuid primary key default extensions.gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    course_id uuid not null references public.courses (id) on delete restrict,
    status text not null default 'recording'
        check (status in ('recording', 'uploaded', 'processing', 'scored', 'failed')),
    -- Verification verdict (spec §44); null until the server scores the run.
    verification text
        check (verification is null or verification in ('verified', 'questionable', 'invalid')),
    started_at timestamptz not null,
    completed_at timestamptz,
    duration_seconds double precision
        check (duration_seconds is null or duration_seconds > 0),
    distance_meters double precision
        check (distance_meters is null or distance_meters >= 0),
    -- Client-computed preview; never authoritative.
    client_score integer
        check (client_score is null or (client_score between 0 and 10000)),
    -- Authoritative results — service role only (no client column grants).
    score integer check (score is null or (score between 0 and 10000)),
    pace_bps integer check (pace_bps is null or (pace_bps between 0 and 10000)),
    smoothness_bps integer check (smoothness_bps is null or (smoothness_bps between 0 and 10000)),
    control_bps integer check (control_bps is null or (control_bps between 0 and 10000)),
    compliance_bps integer check (compliance_bps is null or (compliance_bps between 0 and 10000)),
    confidence_score integer
        check (confidence_score is null or (confidence_score between 0 and 100)),
    scoring_version text references public.scoring_configs (version),
    integrity_flags jsonb,
    device_id text,
    -- ~1 Hz downsampled polyline so maps render without touching raw blobs.
    preview_polyline jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index runs_user_created_idx on public.runs (user_id, created_at desc);
create index runs_course_status_idx on public.runs (course_id, status);

alter table public.runs enable row level security;

-- Column-level client grants: identity/lifecycle/preview columns only.
grant select on public.runs to authenticated;
grant insert (id, user_id, course_id, status, started_at, completed_at,
              duration_seconds, distance_meters, client_score, device_id, preview_polyline)
    on public.runs to authenticated;
grant update (status, completed_at, duration_seconds, distance_meters,
              client_score, preview_polyline)
    on public.runs to authenticated;
grant all on public.runs to service_role;

-- Runs are private to their owner (leaderboard_entries is the public surface).
create policy "users see own runs"
    on public.runs for select
    using (user_id = (select auth.uid()));

create policy "users create own runs"
    on public.runs for insert
    with check (user_id = (select auth.uid()));

create policy "users update own runs"
    on public.runs for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

create trigger runs_set_updated_at
    before update on public.runs
    for each row
    execute function public.set_updated_at();

-- ── Telemetry envelope ────────────────────────────────────────────────────
-- Raw telemetry itself is a gzip NDJSON object in a private Storage bucket;
-- this table stores the pointer + integrity envelope (ADR context in
-- docs/DATABASE.md). Owner + service role only — raw telemetry is NEVER
-- public (spec §66).

create table public.telemetry (
    id uuid primary key default extensions.gen_random_uuid(),
    run_id uuid not null unique references public.runs (id) on delete cascade,
    storage_path text not null,
    schema_version integer not null default 1,
    gps_count integer check (gps_count is null or gps_count >= 0),
    imu_count integer check (imu_count is null or imu_count >= 0),
    byte_size bigint check (byte_size is null or byte_size > 0),
    sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
    uploaded_at timestamptz not null default now()
);

alter table public.telemetry enable row level security;

grant select, insert on public.telemetry to authenticated;
grant all on public.telemetry to service_role;

create policy "owners see own telemetry envelope"
    on public.telemetry for select
    using (
        exists (
            select 1 from public.runs r
            where r.id = run_id and r.user_id = (select auth.uid())
        )
    );

create policy "owners register own telemetry envelope"
    on public.telemetry for insert
    with check (
        exists (
            select 1 from public.runs r
            where r.id = run_id and r.user_id = (select auth.uid())
        )
    );

-- ── Scoring job queue ─────────────────────────────────────────────────────
-- Hybrid flow: the client invokes score-run directly (fast path); this queue
-- is the safety net a pg_cron sweep re-drives so flaky networks and crashed
-- invocations never lose a run (spec §60). Service-role only.

create table public.scoring_jobs (
    id bigint generated always as identity primary key,
    run_id uuid not null unique references public.runs (id) on delete cascade,
    status text not null default 'pending'
        check (status in ('pending', 'processing', 'done', 'failed')),
    attempts integer not null default 0,
    last_error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index scoring_jobs_pending_idx on public.scoring_jobs (created_at)
    where status = 'pending';

alter table public.scoring_jobs enable row level security;
-- No client grants at all: the queue is server machinery.
grant all on public.scoring_jobs to service_role;

create trigger scoring_jobs_set_updated_at
    before update on public.scoring_jobs
    for each row
    execute function public.set_updated_at();

-- Enqueue on upload: any transition into 'uploaded' guarantees a job row.
create or replace function public.enqueue_scoring_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.status = 'uploaded'
        and (tg_op = 'INSERT' or old.status is distinct from 'uploaded') then
        insert into public.scoring_jobs (run_id)
        values (new.id)
        on conflict (run_id) do nothing;
    end if;
    return new;
end;
$$;

create trigger runs_enqueue_scoring_job
    after insert or update of status on public.runs
    for each row
    execute function public.enqueue_scoring_job();
