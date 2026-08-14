-- 0022: one entitlement rule, and the garage's selling point actually wired.
--
-- 1. `has_active_pro` and `has_active_pro_in` held the SAME five conditions,
--    written out twice. This is the check that decides whether someone is a
--    paying customer, and it has already been wrong once: sandbox
--    subscriptions granted production Pro, and a null expiry granted
--    permanent Pro. A rule that important living in two places means the
--    next fix lands in one of them and the other quietly disagrees.
--
-- 2. `my_vehicle_bests` was written for the garage and never called by
--    anything. "Which of my cars is faster on this road" is the reason to
--    pay for a garage, and it was answerable only in SQL.

-- ── one definition ────────────────────────────────────────────────────────

create or replace function public.has_active_pro(p_user uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    -- Delegates rather than restating. `auth.uid()` first so a caller can
    -- never ask about somebody else's entitlement by passing their id.
    select public.has_active_pro_in(
        coalesce((select auth.uid()), p_user),
        'production'
    );
$$;

comment on function public.has_active_pro(uuid) is
    'Production entitlement for the current user. Delegates to '
    'has_active_pro_in so the rule exists exactly once.';

-- ── the garage question, answerable from the app ──────────────────────────

-- Migration 0017 defined this with different OUT parameters, and
-- `create or replace` cannot change a function's return type — it aborts the
-- whole migration. Dropping first is the only way, and getting this wrong
-- breaks `db push` on a fresh database rather than on this one.
drop function if exists public.my_vehicle_bests(uuid);

-- Per-course bests for the caller's own cars, best first. Their own data
-- only: SECURITY INVOKER, so RLS on runs and vehicles applies unchanged and
-- this cannot become a way to read someone else's garage.
create or replace function public.my_vehicle_bests(p_course uuid)
returns table (
    vehicle_id uuid,
    vehicle_name text,
    is_default boolean,
    best_score integer,
    best_duration_seconds double precision,
    run_count bigint,
    last_driven timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
    select v.id,
           v.name,
           v.is_default,
           max(r.score) filter (where r.verification = 'verified'),
           min(r.duration_seconds) filter (where r.verification = 'verified'),
           count(r.id),
           max(r.created_at)
      from public.vehicles v
      left join public.runs r
             on r.vehicle_id = v.id
            and r.course_id = p_course
     where v.user_id = (select auth.uid())
     group by v.id, v.name, v.is_default
     -- Cars you have actually driven here first, then the rest of the
     -- garage, so the comparison leads and the empty slots follow.
     order by max(r.score) filter (where r.verification = 'verified') desc nulls last,
              v.is_default desc,
              v.name;
$$;

revoke all on function public.my_vehicle_bests(uuid) from public, anon;
grant execute on function public.my_vehicle_bests(uuid) to authenticated, service_role;
