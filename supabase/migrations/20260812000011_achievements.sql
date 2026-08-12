-- 0011: achievements (spec §82 — deliberately simple).
-- Awarded by the service role (scoring pipeline / server logic); users read
-- their own and, for public profile display, anyone's.

create table public.achievements (
    id uuid primary key default extensions.gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    kind text not null check (kind in (
        'first_run', 'first_top_100', 'first_top_10', 'first_win',
        'ten_verified_runs', 'ten_course_wins', 'ten_friend_wins',
        'first_ghost_victory', 'first_custom_course'
    )),
    awarded_at timestamptz not null default now(),
    unique (user_id, kind)
);

alter table public.achievements enable row level security;

grant select on public.achievements to authenticated;
grant all on public.achievements to service_role;

-- Achievements are public bragging rights (profile display).
create policy "achievements are readable"
    on public.achievements for select
    using (true);
