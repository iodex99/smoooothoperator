-- 0009: challenges + challenge_participants (spec §§6, 68-69, 79).
--
-- A challenge wraps a course in a competitive frame (daily, public, friend,
-- private) with an invite code for share links. Direct self-join is allowed
-- only for public/daily challenges; friend/private joins flow through the
-- invite path (edge function with the code, L9). State machine per spec §69.

create table public.challenges (
    id uuid primary key default extensions.gen_random_uuid(),
    course_id uuid not null references public.courses (id) on delete cascade,
    creator_id uuid not null references public.profiles (id) on delete cascade,
    type text not null default 'friend'
        check (type in ('daily', 'public', 'friend', 'private')),
    name text check (name is null or char_length(name) <= 80),
    invite_code text not null unique
        default upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10)),
    status text not null default 'active'
        check (status in ('draft', 'active', 'completed', 'expired', 'cancelled')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    expires_at timestamptz
);

create index challenges_course_idx on public.challenges (course_id, status);
create index challenges_creator_idx on public.challenges (creator_id);

alter table public.challenges enable row level security;

grant select on public.challenges to authenticated;
grant insert (id, course_id, creator_id, type, name, expires_at)
    on public.challenges to authenticated;
grant update (name, status, expires_at) on public.challenges to authenticated;
grant delete on public.challenges to authenticated;
grant all on public.challenges to service_role;

-- Creating a challenge requires the course to be visible to you (courses
-- RLS applies inside the subquery — you can't challenge on someone's
-- private course).
create policy "users create their own challenges on visible courses"
    on public.challenges for insert
    with check (
        creator_id = (select auth.uid())
        and exists (select 1 from public.courses c where c.id = course_id)
    );

create policy "creators manage their challenges"
    on public.challenges for update
    using (creator_id = (select auth.uid()))
    with check (creator_id = (select auth.uid()));

create policy "creators delete their challenges"
    on public.challenges for delete
    using (creator_id = (select auth.uid()));

create trigger challenges_set_updated_at
    before update on public.challenges
    for each row
    execute function public.set_updated_at();

-- Spec §69: no invalid state transitions, no resurrections.
create or replace function public.validate_challenge_transition()
returns trigger
language plpgsql
as $$
begin
    if old.status = 'draft' and new.status in ('active', 'cancelled') then
        return new;
    end if;
    if old.status = 'active' and new.status in ('completed', 'expired', 'cancelled') then
        return new;
    end if;
    raise exception 'invalid challenge transition % -> %', old.status, new.status;
end;
$$;

create trigger challenges_validate_transition
    before update of status on public.challenges
    for each row
    when (old.status is distinct from new.status)
    execute function public.validate_challenge_transition();

-- ── Participants ──────────────────────────────────────────────────────────

create table public.challenge_participants (
    id uuid primary key default extensions.gen_random_uuid(),
    challenge_id uuid not null references public.challenges (id) on delete cascade,
    user_id uuid not null references public.profiles (id) on delete cascade,
    run_id uuid references public.runs (id) on delete set null,
    status text not null default 'joined'
        check (status in ('invited', 'joined', 'completed', 'declined')),
    joined_at timestamptz not null default now(),
    unique (challenge_id, user_id)
);

create index challenge_participants_user_idx on public.challenge_participants (user_id);

alter table public.challenge_participants enable row level security;

grant select on public.challenge_participants to authenticated;
grant insert (id, challenge_id, user_id) on public.challenge_participants to authenticated;
grant update (status, run_id) on public.challenge_participants to authenticated;
grant delete on public.challenge_participants to authenticated;
grant all on public.challenge_participants to service_role;

-- Membership helper (security definer: policies on BOTH tables consult
-- membership without recursing into participants' own RLS). Defined after
-- both tables exist — SQL function bodies validate references at creation.
create or replace function public.is_challenge_member(challenge uuid, member uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
    select exists (
        select 1 from public.challenge_participants p
        where p.challenge_id = challenge and p.user_id = member
    ) or exists (
        select 1 from public.challenges c
        where c.id = challenge and c.creator_id = member
    );
$$;

grant execute on function public.is_challenge_member(uuid, uuid) to authenticated, service_role;

create policy "challenges visible to members and public audiences"
    on public.challenges for select
    using (
        creator_id = (select auth.uid())
        or public.is_challenge_member(id, (select auth.uid()))
        or (type in ('public', 'daily') and status in ('active', 'completed'))
    );

-- Standings are visible to everyone in the challenge.
create policy "members see the participant list"
    on public.challenge_participants for select
    using (public.is_challenge_member(challenge_id, (select auth.uid())));

-- Self-join is only open for public/daily active challenges (and the
-- creator can always join their own); invite joins arrive via service role.
create policy "users join open challenges themselves"
    on public.challenge_participants for insert
    with check (
        user_id = (select auth.uid())
        and exists (
            select 1 from public.challenges c
            where c.id = challenge_id
              and c.status = 'active'
              and (c.type in ('public', 'daily') or c.creator_id = (select auth.uid()))
        )
    );

-- You update only your own row, and may link only your own run.
create policy "participants update their own row"
    on public.challenge_participants for update
    using (user_id = (select auth.uid()))
    with check (
        user_id = (select auth.uid())
        and (run_id is null or exists (
            select 1 from public.runs r
            where r.id = run_id and r.user_id = (select auth.uid())
        ))
    );

-- Leave, or get removed by the creator.
create policy "participants leave or creators remove"
    on public.challenge_participants for delete
    using (
        user_id = (select auth.uid())
        or exists (
            select 1 from public.challenges c
            where c.id = challenge_id and c.creator_id = (select auth.uid())
        )
    );
