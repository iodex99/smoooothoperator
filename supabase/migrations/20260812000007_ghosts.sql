-- 0007: ghosts — compact normalized replays of verified runs (spec §§32-36).
--
-- A ghost stores ONLY (progress, elapsed) pairs — never raw GPS, never
-- coordinates (spec §35). Rows are created by the score-run edge function
-- (service role) for verified, finished runs. Visibility follows the
-- owner's profiles.ghost_visibility setting (spec §70): 'everyone' shares
-- publicly, 'friends' behaves as owner-only until migration 0008 introduces
-- friendships and replaces the policy, 'nobody' hides them.

create table public.ghosts (
    id uuid primary key default extensions.gen_random_uuid(),
    run_id uuid not null unique references public.runs (id) on delete cascade,
    course_id uuid not null references public.courses (id) on delete cascade,
    user_id uuid not null references public.profiles (id) on delete cascade,
    -- {"points": [[progress, elapsedSeconds], ...], "totalSeconds": n}
    trajectory jsonb not null,
    score integer not null check (score between 0 and 10000),
    duration_seconds double precision not null check (duration_seconds > 0),
    created_at timestamptz not null default now()
);

create index ghosts_course_score_idx on public.ghosts (course_id, score desc);
create index ghosts_user_idx on public.ghosts (user_id);

alter table public.ghosts enable row level security;

grant select on public.ghosts to authenticated;
grant all on public.ghosts to service_role;

-- Owners always race their own ghosts; others only when the owner's
-- privacy setting allows everyone.
create policy "ghost visibility follows owner setting"
    on public.ghosts for select
    using (
        user_id = (select auth.uid())
        or exists (
            select 1 from public.profiles p
            where p.id = user_id and p.ghost_visibility = 'everyone'
        )
    );
