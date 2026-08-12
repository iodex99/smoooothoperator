-- 0008: friendships (spec §28) — request/accept/decline/remove, nothing more
-- (no chat, no feed, no follower graph: spec §80). Also upgrades the
-- 'friends' visibility tiers that courses (0004) and ghosts (0007)
-- deliberately deferred until this table existed.

create table public.friendships (
    id uuid primary key default extensions.gen_random_uuid(),
    requester_id uuid not null references public.profiles (id) on delete cascade,
    addressee_id uuid not null references public.profiles (id) on delete cascade,
    status text not null default 'pending'
        check (status in ('pending', 'accepted', 'declined')),
    created_at timestamptz not null default now(),
    responded_at timestamptz,
    check (requester_id <> addressee_id)
);

-- One relationship per pair, regardless of direction.
create unique index friendships_pair_idx
    on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));

create index friendships_addressee_idx on public.friendships (addressee_id, status);

alter table public.friendships enable row level security;

grant select on public.friendships to authenticated;
grant insert (requester_id, addressee_id) on public.friendships to authenticated;
grant update (status, responded_at) on public.friendships to authenticated;
grant delete on public.friendships to authenticated;
grant all on public.friendships to service_role;

-- Participants see their own relationships; nobody else's.
create policy "participants see their friendships"
    on public.friendships for select
    using (requester_id = (select auth.uid()) or addressee_id = (select auth.uid()));

-- You can only ask on your own behalf (status defaults to pending; the
-- insert grant excludes the status column entirely).
create policy "users send their own requests"
    on public.friendships for insert
    with check (requester_id = (select auth.uid()));

-- Only the addressee answers a request.
create policy "addressee answers the request"
    on public.friendships for update
    using (addressee_id = (select auth.uid()))
    with check (addressee_id = (select auth.uid()));

-- Either side may remove the relationship (spec §28: remove friend).
create policy "either side may remove"
    on public.friendships for delete
    using (requester_id = (select auth.uid()) or addressee_id = (select auth.uid()));

-- State machine (spec §69 spirit): pending → accepted/declined only; a
-- resolved request never reopens.
create or replace function public.validate_friendship_transition()
returns trigger
language plpgsql
as $$
begin
    if old.status = 'pending' and new.status in ('accepted', 'declined') then
        new.responded_at := now();
        return new;
    end if;
    raise exception 'invalid friendship transition % -> %', old.status, new.status;
end;
$$;

create trigger friendships_validate_transition
    before update of status on public.friendships
    for each row
    when (old.status is distinct from new.status)
    execute function public.validate_friendship_transition();

-- Security-definer helper so OTHER tables' policies can consult the graph
-- without tripping over friendships' own RLS.
create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
    select exists (
        select 1 from public.friendships f
        where f.status = 'accepted'
          and ((f.requester_id = a and f.addressee_id = b)
            or (f.requester_id = b and f.addressee_id = a))
    );
$$;

grant execute on function public.are_friends(uuid, uuid) to anon, authenticated, service_role;

-- ── Upgrade deferred 'friends' visibility tiers ───────────────────────────

drop policy "courses visible by visibility rules" on public.courses;
create policy "courses visible by visibility rules"
    on public.courses for select
    using (
        (visibility = 'public' and status = 'active')
        or creator_id = (select auth.uid())
        or (visibility = 'friends' and status = 'active'
            and public.are_friends(creator_id, (select auth.uid())))
    );

drop policy "ghost visibility follows owner setting" on public.ghosts;
create policy "ghost visibility follows owner setting"
    on public.ghosts for select
    using (
        user_id = (select auth.uid())
        or exists (
            select 1 from public.profiles p
            where p.id = user_id
              and (
                  p.ghost_visibility = 'everyone'
                  or (p.ghost_visibility = 'friends'
                      and public.are_friends(p.id, (select auth.uid())))
              )
        )
    );
