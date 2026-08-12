-- 0003: scoring_configs — versioned scoring configuration (spec §§42-43).
-- The server scorer loads the active config; clients read it for provisional
-- scoring. Every run stores the scoringVersion it was scored with; old runs
-- keep their original scoring. Config *content* lands in Phase L4.

create table public.scoring_configs (
    version text primary key
        check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
    config jsonb not null,
    active boolean not null default false,
    created_at timestamptz not null default now()
);

comment on table public.scoring_configs is
    'Versioned ScoringConfig JSON consumed by both the Swift and TS scorers.';

-- At most one active config at any time.
create unique index scoring_configs_single_active
    on public.scoring_configs (active)
    where active;

alter table public.scoring_configs enable row level security;

-- Clients need the config to compute provisional scores; it contains no
-- secrets. Writes are service-role only (no client grants, no policies).
grant select on public.scoring_configs to anon, authenticated;
grant all on public.scoring_configs to service_role;

create policy "scoring configs are publicly readable"
    on public.scoring_configs
    for select
    using (true);
