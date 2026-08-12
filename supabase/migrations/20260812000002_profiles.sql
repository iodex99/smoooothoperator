-- 0002: profiles — the public identity attached to each auth user.
-- RLS is enabled in the same migration that creates the table: there is
-- never a window where a table exists unprotected.

create table public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    username text not null unique
        check (username ~ '^[a-z0-9_]{3,20}$'),
    display_name text not null default '',
    avatar_url text,
    -- ISO 3166-1 alpha-2; never inferred from raw GPS (privacy: spec §62).
    country text check (country is null or country ~ '^[A-Z]{2}$'),
    region text,
    city text,
    -- Smooooth Rating (spec §49). 0 = unrated; engine lands in L5.
    rating integer not null default 0 check (rating >= 0),
    rating_tier text not null default 'unranked',
    -- Ghost privacy controls (spec §70). Default favors competition.
    ghost_visibility text not null default 'everyone'
        check (ghost_visibility in ('everyone', 'friends', 'nobody')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on table public.profiles is
    'Public driver identity. Raw location/telemetry never lives here.';

alter table public.profiles enable row level security;

-- Explicit grants (defense in depth — RLS restricts rows, grants restrict
-- verbs and columns). Clients may read everything and update only the
-- user-editable columns: rating/rating_tier are server-computed, so even the
-- row owner cannot write them. No INSERT/DELETE for client roles at all.
grant select on public.profiles to anon, authenticated;
grant update (username, display_name, avatar_url, country, region, city, ghost_visibility)
    on public.profiles to authenticated;
grant all on public.profiles to service_role;

-- Profiles are the public face of leaderboards: readable by any
-- authenticated user AND anonymously (challenge share links show the
-- creator's name before signup — spec §79). Only deliberately public
-- columns exist on this table.
create policy "profiles are publicly readable"
    on public.profiles
    for select
    using (true);

-- A user may update only their own profile.
create policy "users update own profile"
    on public.profiles
    for update
    using ((select auth.uid()) = id)
    with check ((select auth.uid()) = id);

-- No insert/delete policies: rows are created by the signup trigger below
-- (security definer) and removed via auth.users cascade on account deletion.

create trigger profiles_set_updated_at
    before update on public.profiles
    for each row
    execute function public.set_updated_at();

-- Signup trigger: every new auth user gets a profile row. Username comes
-- from signup metadata when present, otherwise a collision-safe placeholder
-- the user can change later.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, username, display_name)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data ->> 'username',
            'driver_' || substr(replace(new.id::text, '-', ''), 1, 12)
        ),
        coalesce(new.raw_user_meta_data ->> 'display_name', '')
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.handle_new_user();
