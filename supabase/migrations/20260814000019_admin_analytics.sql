-- 0019: the owner's analytics (spec §98 — operator visibility).
--
-- THE SECURITY MODEL IS THE FEATURE. Every function here is SECURITY
-- DEFINER, which means it runs as the table owner and sees *every* row in
-- the database regardless of RLS. That is the only way to count other
-- people's runs and subscriptions — and it is also exactly how a data
-- breach happens if the gate is wrong.
--
-- So the gate is deliberately narrow:
--   * `is_admin()` takes NO ARGUMENTS and reads `auth.uid()` directly. It
--     cannot be told who to check. `challenge_candidates` was written with
--     a caller-supplied uid and leaked any user's drive history to anyone
--     who passed someone else's id; that mistake is not repeatable here.
--   * The `admins` table has NO grants for anon or authenticated — not even
--     select. Nobody can read who the admins are, and nobody can add
--     themselves through the API. Membership is granted in SQL only.
--   * Every analytics function raises rather than returning an empty set,
--     so a permission bug is loud instead of looking like "no data yet".

create table public.admins (
    user_id uuid primary key references public.profiles (id) on delete cascade,
    note text,
    added_at timestamptz not null default now()
);

alter table public.admins enable row level security;

-- No policies, and no grants to anon/authenticated: the API cannot touch
-- this table at all. RLS with zero policies denies everything by default,
-- and the missing grant means it fails before RLS is even consulted.
revoke all on public.admins from anon, authenticated;
grant all on public.admins to service_role;

comment on table public.admins is
    'Operator accounts. Membership is granted by direct SQL only — there is '
    'deliberately no API path to read or modify this table.';

-- Prices live in the database rather than in code (spec §75: no hard-coded
-- prices anywhere). Without them there is no honest MRR — and a guessed
-- price is worse than no number at all.
create table public.product_prices (
    product_id text primary key check (product_id in (
        'smooooth.pro.weekly', 'smooooth.pro.monthly', 'smooooth.pro.yearly'
    )),
    -- Minor units (cents/pence/paise) to avoid float money.
    price_minor integer not null check (price_minor >= 0),
    currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
    period_days integer not null check (period_days > 0),
    updated_at timestamptz not null default now()
);

alter table public.product_prices enable row level security;
revoke all on public.product_prices from anon, authenticated;
grant all on public.product_prices to service_role;

-- Period lengths are facts about the products. The prices are the owner's
-- to set in App Store Connect and mirror here; zero means "not yet told",
-- which the overview reports honestly instead of counting as free revenue.
insert into public.product_prices (product_id, price_minor, currency, period_days)
values
    ('smooooth.pro.weekly',  0, 'USD',   7),
    ('smooooth.pro.monthly', 0, 'USD',  30),
    ('smooooth.pro.yearly',  0, 'USD', 365)
on conflict (product_id) do nothing;

-- ── the gate ──────────────────────────────────────────────────────────────

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.admins a where a.user_id = auth.uid()
    );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated, service_role;

create or replace function public.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.is_admin() then
        -- Loud, not silent. An analytics screen that shows zeros because of
        -- a permission bug is indistinguishable from a product with no users.
        raise exception 'not authorised' using errcode = '42501';
    end if;
end;
$$;

revoke all on function public.require_admin() from public;
grant execute on function public.require_admin() to authenticated, service_role;

-- ── revenue ───────────────────────────────────────────────────────────────

-- Normalised monthly value of every subscription that is actually paying.
-- Sandbox is excluded: a sandbox subscription is a test, and counting it as
-- revenue is how a dashboard starts lying to its owner.
create or replace function public.admin_mrr_minor()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(sum(
        (p.price_minor::numeric * 30.0 / p.period_days::numeric)
    ), 0)::bigint
      from public.subscriptions s
      join public.product_prices p on p.product_id = s.product_id
     where s.environment = 'production'
       -- Grace period is still a paying customer; billing retry has already
       -- failed to charge, so it is not counted.
       and s.status in ('active', 'in_grace_period');
$$;

revoke all on function public.admin_mrr_minor() from public, anon, authenticated;

-- ── the numbers ───────────────────────────────────────────────────────────

create or replace function public.admin_overview()
returns table (
    total_users bigint,
    new_users_7d bigint,
    new_users_30d bigint,
    paying_users bigint,
    sandbox_users bigint,
    grace_users bigint,
    churned_users bigint,
    mrr_minor bigint,
    arr_minor bigint,
    currency text,
    prices_configured boolean,
    total_courses bigint,
    platform_courses bigint,
    user_courses bigint,
    countries_covered bigint,
    total_runs bigint,
    verified_runs bigint,
    unranked_runs bigint,
    runs_7d bigint,
    drivers_7d bigint,
    total_vehicles bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    select
        (select count(*) from public.profiles),
        (select count(*) from public.profiles where created_at >= now() - interval '7 days'),
        (select count(*) from public.profiles where created_at >= now() - interval '30 days'),
        (select count(distinct user_id) from public.subscriptions
          where environment = 'production' and status in ('active', 'in_grace_period')),
        (select count(distinct user_id) from public.subscriptions where environment = 'sandbox'),
        (select count(distinct user_id) from public.subscriptions
          where environment = 'production' and status = 'in_grace_period'),
        (select count(distinct user_id) from public.subscriptions
          where environment = 'production' and status in ('expired', 'revoked')),
        public.admin_mrr_minor(),
        public.admin_mrr_minor() * 12,
        -- Qualified: `currency` is also an OUT parameter of this function,
        -- and plpgsql refuses the ambiguity rather than guessing.
        (select coalesce(min(pp.currency), 'USD') from public.product_prices pp),
        (select bool_or(pp.price_minor > 0) from public.product_prices pp),
        (select count(*) from public.courses where status = 'active'),
        (select count(*) from public.courses where status = 'active' and creator_id is null),
        (select count(*) from public.courses where status = 'active' and creator_id is not null),
        (select count(distinct country) from public.courses where status = 'active' and country is not null),
        (select count(*) from public.runs),
        (select count(*) from public.runs where verification = 'verified'),
        (select count(*) from public.runs where verification <> 'verified'),
        (select count(*) from public.runs where created_at >= now() - interval '7 days'),
        (select count(distinct user_id) from public.runs where created_at >= now() - interval '7 days'),
        (select count(*) from public.vehicles);
end;
$$;

-- Where the catalog actually is, and whether anyone drives it. A region with
-- 40 courses and no runs is a very different problem from one with 2 courses
-- and 900 runs, and only the pair of numbers tells them apart.
create or replace function public.admin_courses_by_region()
returns table (
    country text,
    region text,
    city text,
    course_count bigint,
    run_count bigint,
    driver_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    select c.country, c.region, c.city,
           count(distinct c.id),
           count(r.id),
           count(distinct r.user_id)
      from public.courses c
      left join public.runs r on r.course_id = c.id
     where c.status = 'active'
     group by c.country, c.region, c.city
     order by count(r.id) desc, count(distinct c.id) desc;
end;
$$;

create or replace function public.admin_top_courses(p_limit integer default 20)
returns table (
    course_id uuid,
    name text,
    country text,
    region text,
    city text,
    run_count bigint,
    driver_count bigint,
    verified_count bigint,
    best_score integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    select c.id, c.name, c.country, c.region, c.city,
           count(r.id),
           count(distinct r.user_id),
           count(r.id) filter (where r.verification = 'verified'),
           max(r.score)
      from public.courses c
      join public.runs r on r.course_id = c.id
     group by c.id, c.name, c.country, c.region, c.city
     order by count(r.id) desc
     limit least(greatest(p_limit, 1), 200);
end;
$$;

-- Activity by where the DRIVING happened, not where the driver says they
-- live. A profile's country is self-reported and usually null; the country
-- of the course they actually drove is a fact.
create or replace function public.admin_regions_by_activity(p_days integer default 30)
returns table (
    country text,
    region text,
    driver_count bigint,
    run_count bigint,
    paying_driver_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    select c.country, c.region,
           count(distinct r.user_id),
           count(r.id),
           count(distinct r.user_id) filter (
               where exists (
                   select 1 from public.subscriptions s
                    where s.user_id = r.user_id
                      and s.environment = 'production'
                      and s.status in ('active', 'in_grace_period')
               )
           )
      from public.runs r
      join public.courses c on c.id = r.course_id
     where r.created_at >= now() - make_interval(days => least(greatest(p_days, 1), 3650))
     group by c.country, c.region
     order by count(distinct r.user_id) desc, count(r.id) desc;
end;
$$;

create or replace function public.admin_revenue_by_product()
returns table (
    product_id text,
    subscribers bigint,
    price_minor integer,
    currency text,
    period_days integer,
    mrr_minor bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    select p.product_id,
           count(s.id) filter (
               where s.environment = 'production'
                 and s.status in ('active', 'in_grace_period')
           ),
           p.price_minor,
           p.currency,
           p.period_days,
           (count(s.id) filter (
               where s.environment = 'production'
                 and s.status in ('active', 'in_grace_period')
           ) * p.price_minor * 30 / p.period_days)::bigint
      from public.product_prices p
      left join public.subscriptions s on s.product_id = p.product_id
     group by p.product_id, p.price_minor, p.currency, p.period_days
     order by p.period_days;
end;
$$;

-- A daily series for charting. Returns a row per day even when nothing
-- happened, because a gap in a chart reads as missing data rather than as
-- a quiet Tuesday.
create or replace function public.admin_growth_daily(p_days integer default 30)
returns table (
    day date,
    signups bigint,
    runs bigint,
    active_drivers bigint,
    new_subscriptions bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    span integer := least(greatest(p_days, 1), 365);
begin
    perform public.require_admin();
    return query
    select d.day::date,
           (select count(*) from public.profiles p
             where p.created_at >= d.day and p.created_at < d.day + interval '1 day'),
           (select count(*) from public.runs r
             where r.created_at >= d.day and r.created_at < d.day + interval '1 day'),
           (select count(distinct r.user_id) from public.runs r
             where r.created_at >= d.day and r.created_at < d.day + interval '1 day'),
           (select count(*) from public.subscriptions s
             where s.created_at >= d.day and s.created_at < d.day + interval '1 day'
               and s.environment = 'production')
      from generate_series(
          date_trunc('day', now()) - make_interval(days => span - 1),
          date_trunc('day', now()),
          interval '1 day'
      ) as d(day)
     order by d.day;
end;
$$;

-- Retention, stated plainly: of the drivers who ever recorded a run, how
-- many came back on a later day.
create or replace function public.admin_retention()
returns table (
    drivers_ever bigint,
    drivers_returned bigint,
    drivers_5_plus_runs bigint,
    median_runs_per_driver numeric,
    runs_per_driver_avg numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    with per_driver as (
        select user_id,
               count(*) as run_count,
               count(distinct date_trunc('day', created_at)) as active_days
          from public.runs
         group by user_id
    )
    select count(*),
           count(*) filter (where active_days > 1),
           count(*) filter (where run_count >= 5),
           coalesce(percentile_cont(0.5) within group (order by run_count), 0)::numeric,
           coalesce(avg(run_count), 0)::numeric
      from per_driver;
end;
$$;

-- Analytics are readable by a signed-in admin and by the service role.
-- `public` and `anon` are revoked explicitly rather than relied upon.
do $$
declare fn text;
begin
    foreach fn in array array[
        'admin_overview()',
        'admin_courses_by_region()',
        'admin_top_courses(integer)',
        'admin_regions_by_activity(integer)',
        'admin_revenue_by_product()',
        'admin_growth_daily(integer)',
        'admin_retention()'
    ] loop
        execute format('revoke all on function public.%s from public, anon', fn);
        execute format('grant execute on function public.%s to authenticated, service_role', fn);
    end loop;
end;
$$;
