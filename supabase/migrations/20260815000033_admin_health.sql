-- 0033: making the silent failures visible.
--
-- The audit record named observability as an axis with nothing under it:
--
--   "If scoring starts failing in production, nothing tells anyone. The
--    scoring_jobs table records attempts and failures, so the data exists —
--    nothing watches it."
--
-- This does not invent an observability stack. It surfaces the four things
-- in this product that fail QUIETLY — where the app carries on looking
-- normal, nobody gets an error, and the damage accumulates:
--
--   1. SCORING JOBS THAT GAVE UP. A run that failed five attempts is a
--      drive somebody recorded and will never see a score for. They are not
--      told. Their app just shows a run that never finished scoring.
--
--   2. SCORING JOBS PAST DUE. `next_attempt_at` in the past and still
--      pending means the pg_cron sweeper is not running — which is a config
--      problem (app.functions_url / app.service_role_key) that produces
--      exactly zero errors anywhere, because the sweeper returns 0 rather
--      than failing when unconfigured.
--
--   3. SUBSCRIPTIONS ATTACHED TO NOBODY. Money arrived and no account got
--      Pro. `user_id` is NULL when Apple's notification carried no
--      appAccountToken and the client has not claimed it. One or two is
--      normal and self-heals on next launch; a growing pile is revenue
--      collected for a product nobody received.
--
--   4. UPLOADED RUNS THAT WERE NEVER SCORED. The end-to-end version of (1)
--      and (2): whatever the cause, this is the count of drives sitting in
--      the database with no verdict.
--
-- Each comes with the age of the OLDEST one, because a count alone cannot
-- tell "three failed this morning" from "three have been failing since
-- March".

create or replace function public.admin_health()
returns table (
    failed_scoring_jobs bigint,
    oldest_failed_job_hours numeric,
    overdue_scoring_jobs bigint,
    oldest_overdue_job_hours numeric,
    unattributed_subscriptions bigint,
    oldest_unattributed_hours numeric,
    unscored_runs bigint,
    oldest_unscored_hours numeric,
    last_error text
)
-- plpgsql with `perform public.require_admin()`, matching every other
-- analytics function: require_admin returns void, so it gates as a
-- statement and cannot be used as a WHERE predicate.
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    perform public.require_admin();
    return query
    select
        (select count(*) from public.scoring_jobs where status = 'failed'),
        (select round(extract(epoch from (now() - min(updated_at))) / 3600, 1)
           from public.scoring_jobs where status = 'failed'),

        -- Past its own retry time and still waiting: nothing is driving it.
        (select count(*) from public.scoring_jobs
          where status = 'pending' and next_attempt_at < now() - interval '15 minutes'),
        (select round(extract(epoch from (now() - min(next_attempt_at))) / 3600, 1)
           from public.scoring_jobs
          where status = 'pending' and next_attempt_at < now() - interval '15 minutes'),

        -- Money in, nobody entitled. Recent ones are normal — the client
        -- claims them on next launch — so only those old enough to have had
        -- the chance are counted.
        (select count(*) from public.subscriptions
          where user_id is null and environment = 'production'
            and created_at < now() - interval '24 hours'),
        (select round(extract(epoch from (now() - min(created_at))) / 3600, 1)
           from public.subscriptions
          where user_id is null and environment = 'production'
            and created_at < now() - interval '24 hours'),

        (select count(*) from public.runs
          where verification is null and completed_at is not null
            and completed_at < now() - interval '1 hour'),
        (select round(extract(epoch from (now() - min(completed_at))) / 3600, 1)
           from public.runs
          where verification is null and completed_at is not null
            and completed_at < now() - interval '1 hour'),

        -- The most recent thing that actually went wrong, in its own words.
        -- A count tells you something is broken; this tends to tell you what.
        -- Qualified: this function has an OUT parameter of the same name,
        -- and plpgsql resolves the bare identifier to that, not the column.
        (select sj.last_error from public.scoring_jobs sj
          where sj.last_error is not null
          order by sj.updated_at desc limit 1);
end;
$$;

comment on function public.admin_health() is
    'The four things in this product that fail quietly: scoring jobs that '
    'gave up, jobs nothing is driving, subscriptions attached to no account, '
    'and runs that were never scored. Each with the age of the oldest, '
    'because a count cannot tell "this morning" from "since March".';

revoke all on function public.admin_health() from public, anon;
grant execute on function public.admin_health() to authenticated, service_role;
