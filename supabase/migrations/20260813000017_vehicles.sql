-- 0017: the garage — multiple cars per driver (spec §§13, 74).
--
-- A driver who owns more than one car wants to know which one is faster on
-- a road, and to see their cars ranked against each other. That is a
-- genuine reason to subscribe, so the free tier gets ONE car and Pro gets a
-- garage.
--
-- The vehicle is recorded ON THE RUN, not on the profile, because the
-- question is always "which car drove this?". Deleting a car must never
-- delete the drives you did in it — the run keeps its history and the
-- reference simply goes null.

create table public.vehicles (
    id uuid primary key default extensions.gen_random_uuid(),
    user_id uuid not null references public.profiles (id) on delete cascade,
    -- What the driver calls it: "The Golf", "Dad's Civic".
    name text not null
        check (char_length(name) between 1 and 40),
    make text check (make is null or char_length(make) <= 40),
    model text check (model is null or char_length(model) <= 40),
    year smallint check (year is null or year between 1900 and 2100),
    -- Pre-selected for new runs. Exactly one per driver (enforced below).
    is_default boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index vehicles_user_idx on public.vehicles (user_id);

-- At most one default per driver. A partial unique index says exactly that
-- and lets every other row be non-default.
create unique index vehicles_one_default_per_user
    on public.vehicles (user_id)
    where is_default;

alter table public.vehicles enable row level security;

grant select, insert, delete on public.vehicles to authenticated;
-- Clients may rename and re-flag their own cars; nothing else is theirs.
grant update (name, make, model, year, is_default) on public.vehicles to authenticated;
grant all on public.vehicles to service_role;

create policy "drivers manage their own vehicles"
    on public.vehicles
    for all
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

create trigger vehicles_set_updated_at
    before update on public.vehicles
    for each row
    execute function public.set_updated_at();

-- ── The free tier gets one car ────────────────────────────────────────────
-- Enforced in the database, not just the app: a client-side limit is a
-- suggestion (the daily-run allowance taught us that the hard way).
create or replace function public.limit_vehicles_per_driver()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    owned integer;
begin
    -- Service role (imports, support) is unrestricted.
    if current_user not in ('authenticated', 'anon') then
        return new;
    end if;
    if public.has_active_pro(new.user_id) then
        return new;
    end if;
    select count(*) into owned
      from public.vehicles v
     where v.user_id = new.user_id;
    if owned >= 1 then
        raise exception 'the free tier includes one vehicle'
            using errcode = '54000';
    end if;
    return new;
end;
$$;

create trigger vehicles_free_tier_ceiling
    before insert on public.vehicles
    for each row
    execute function public.limit_vehicles_per_driver();

-- ── Which car drove this run ──────────────────────────────────────────────
-- SET NULL on delete: selling a car does not erase the drives you did in it.
alter table public.runs
    add column vehicle_id uuid references public.vehicles (id) on delete set null;

grant update (vehicle_id) on public.runs to authenticated;

comment on column public.runs.vehicle_id is
    'Which car drove this. Nullable: runs predate the garage, and deleting a vehicle keeps its runs.';

-- The leaderboard carries it too, so a board can show WHAT people drove and
-- a driver can compare their own cars on the same road.
alter table public.leaderboard_entries
    add column vehicle_id uuid references public.vehicles (id) on delete set null;

-- A run's vehicle must belong to the run's owner. Without this a client
-- could attribute their drive to someone else's car.
create or replace function public.validate_run_vehicle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    owner uuid;
begin
    if new.vehicle_id is null then
        return new;
    end if;
    select v.user_id into owner from public.vehicles v where v.id = new.vehicle_id;
    if owner is null or owner <> new.user_id then
        raise exception 'that vehicle does not belong to this driver'
            using errcode = '42501';
    end if;
    return new;
end;
$$;

create trigger runs_validate_vehicle
    before insert or update on public.runs
    for each row
    execute function public.validate_run_vehicle();

-- ── Per-vehicle bests, for the "which of my cars is faster" question ──────
create or replace function public.my_vehicle_bests(p_course uuid)
returns table (
    vehicle_id uuid,
    vehicle_name text,
    best_score integer,
    best_duration double precision,
    runs integer
)
language sql
security definer
stable
set search_path = ''
as $$
    select
        v.id,
        v.name,
        max(r.score)::int,
        min(r.duration_seconds),
        count(*)::int
    from public.runs r
    join public.vehicles v on v.id = r.vehicle_id
    where r.user_id = (select auth.uid())
      and r.course_id = p_course
      and r.verification = 'verified'
      and r.score is not null
    group by v.id, v.name
    order by 3 desc;
$$;

revoke all on function public.my_vehicle_bests(uuid) from public, anon;
grant execute on function public.my_vehicle_bests(uuid) to authenticated;
