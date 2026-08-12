-- 0004: courses + course_checkpoints (spec §§23-24, 64).
-- Client roles are READ-ONLY on both tables: course creation/publishing goes
-- through the validated edge function path (Phase L8) with the service role,
-- so unvalidated geometry can never enter the catalog. benchmark_seconds is a
-- REFERENCE BENCHMARK, clearly distinct from user records — never a
-- fabricated human result (spec §57).

create table public.courses (
    id uuid primary key default extensions.gen_random_uuid(),
    name text not null
        check (char_length(name) between 3 and 80),
    description text
        check (description is null or char_length(description) <= 500),
    -- NULL creator = platform course.
    creator_id uuid references public.profiles (id) on delete set null,
    city text,
    region text,
    country text check (country is null or country ~ '^[A-Z]{2}$'),
    distance_meters double precision not null
        check (distance_meters > 0),
    estimated_duration_seconds integer
        check (estimated_duration_seconds is null or estimated_duration_seconds > 0),
    difficulty smallint not null default 1
        check (difficulty between 1 and 5),
    turn_count integer not null default 0
        check (turn_count >= 0),
    geometry extensions.geography(linestring, 4326) not null,
    start_point extensions.geography(point, 4326) not null,
    finish_point extensions.geography(point, 4326) not null,
    benchmark_seconds integer
        check (benchmark_seconds is null or benchmark_seconds > 0),
    visibility text not null default 'public'
        check (visibility in ('public', 'friends', 'private')),
    status text not null default 'active'
        check (status in ('draft', 'active', 'archived', 'removed')),
    version integer not null default 1
        check (version >= 1),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index courses_active_country_idx
    on public.courses (country)
    where status = 'active';

create index courses_geometry_idx
    on public.courses
    using gist (geometry);

alter table public.courses enable row level security;

grant select on public.courses to anon, authenticated;
grant all on public.courses to service_role;

-- Visible when: an active public course (includes anon — share links), or
-- you created it (any status: creators see their drafts/archives).
-- 'friends' visibility intentionally behaves as creator-only until the
-- friendships table exists (migration 0008 replaces this policy).
create policy "courses visible by visibility rules"
    on public.courses
    for select
    using (
        (visibility = 'public' and status = 'active')
        or creator_id = (select auth.uid())
    );

create trigger courses_set_updated_at
    before update on public.courses
    for each row
    execute function public.set_updated_at();

-- ── Checkpoints ───────────────────────────────────────────────────────────

create table public.course_checkpoints (
    id uuid primary key default extensions.gen_random_uuid(),
    course_id uuid not null references public.courses (id) on delete cascade,
    sequence integer not null check (sequence >= 0),
    center extensions.geography(point, 4326) not null,
    radius_meters double precision not null
        check (radius_meters between 5 and 500),
    unique (course_id, sequence)
);

comment on table public.course_checkpoints is
    'Ordered gates: 0 = start, max(sequence) = finish. Drive validation, progress, ghosts, segment scoring.';

alter table public.course_checkpoints enable row level security;

grant select on public.course_checkpoints to anon, authenticated;
grant all on public.course_checkpoints to service_role;

-- Checkpoints inherit their course's visibility.
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
              )
        )
    );
