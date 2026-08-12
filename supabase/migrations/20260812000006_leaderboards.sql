-- 0006: leaderboard_entries — the public competitive surface (spec §47).
--
-- One row per (course, user): the user's best VERIFIED run, upserted
-- transactionally by the score-run edge function (service role). Clients
-- never write here; only verified runs ever enter (enforced by the sole
-- writer). Rank is computed on read via window function — always
-- consistent, no refresh machinery (see docs/DATABASE.md).

create table public.leaderboard_entries (
    id uuid primary key default extensions.gen_random_uuid(),
    course_id uuid not null references public.courses (id) on delete cascade,
    user_id uuid not null references public.profiles (id) on delete cascade,
    run_id uuid not null unique references public.runs (id) on delete cascade,
    score integer not null check (score between 0 and 10000),
    duration_seconds double precision not null check (duration_seconds > 0),
    smoothness_bps integer check (smoothness_bps is null or (smoothness_bps between 0 and 10000)),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (course_id, user_id)
);

create index leaderboard_entries_rank_idx
    on public.leaderboard_entries (course_id, score desc);

alter table public.leaderboard_entries enable row level security;

-- World-readable (share links show standings before signup); writes are
-- service-role machinery only.
grant select on public.leaderboard_entries to anon, authenticated;
grant all on public.leaderboard_entries to service_role;

create policy "leaderboards are publicly readable"
    on public.leaderboard_entries for select
    using (true);

create trigger leaderboard_entries_set_updated_at
    before update on public.leaderboard_entries
    for each row
    execute function public.set_updated_at();

-- Ranked view with public identity attached. security_invoker: the caller's
-- RLS applies to the underlying tables (both are world-readable anyway).
-- Ties: higher score wins; then faster time; then earlier submission.
create view public.course_leaderboards
with (security_invoker = true) as
select
    entries.course_id,
    entries.user_id,
    entries.run_id,
    entries.score,
    entries.duration_seconds,
    entries.smoothness_bps,
    entries.created_at,
    row_number() over (
        partition by entries.course_id
        order by entries.score desc, entries.duration_seconds asc, entries.created_at asc
    ) as rank,
    profiles.username,
    profiles.display_name,
    profiles.country
from public.leaderboard_entries entries
join public.profiles profiles on profiles.id = entries.user_id;

grant select on public.course_leaderboards to anon, authenticated, service_role;
