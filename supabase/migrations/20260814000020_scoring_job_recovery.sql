-- 0020: actually re-drive stale scoring jobs (audit finding 8).
--
-- The sweeper flipped `processing → pending` every minute and stopped there.
-- Nothing ever invoked `score-run` again, so a job whose worker crashed was
-- reset forever and its run never got an authoritative score. `attempts` was
-- never incremented either, so a job that failed for a permanent reason
-- (corrupt telemetry, deleted course) retried until the end of time and
-- nothing recorded that it was hopeless.
--
-- Three changes:
--   * count the attempt, so a poisoned job eventually stops;
--   * give up loudly after `maxAttempts` instead of cycling silently;
--   * actually call the scorer, via pg_net.

alter table public.scoring_jobs
    add column if not exists next_attempt_at timestamptz not null default now();

create index if not exists scoring_jobs_retry_idx
    on public.scoring_jobs (next_attempt_at)
    where status = 'pending';

-- The old signature took no arguments; leaving it in place would make
-- `recover_stale_scoring_jobs()` ambiguous rather than replaced.
drop function if exists public.recover_stale_scoring_jobs();

create or replace function public.recover_stale_scoring_jobs(
    p_max_attempts integer default 5,
    p_stale_after interval default interval '5 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    recovered integer;
begin
    -- A job that has burned through its attempts is not retried again. It is
    -- marked failed with a reason, so it shows up as a problem to look at
    -- rather than disappearing into a retry loop.
    update public.scoring_jobs
       set status = 'failed',
           last_error = coalesce(last_error, 'gave up after ' || attempts || ' attempts'),
           updated_at = now()
     where status = 'processing'
       and updated_at < now() - p_stale_after
       and attempts >= p_max_attempts;

    -- Everything else goes back in the queue, with the attempt counted and
    -- an exponential backoff so a job that fails fast cannot spin.
    update public.scoring_jobs
       set status = 'pending',
           attempts = attempts + 1,
           next_attempt_at = now() + (interval '30 seconds' * power(2, least(attempts, 5))),
           updated_at = now()
     where status = 'processing'
       and updated_at < now() - p_stale_after
       and attempts < p_max_attempts;

    get diagnostics recovered = row_count;
    return recovered;
end;
$$;

revoke all on function public.recover_stale_scoring_jobs(integer, interval) from public, anon, authenticated;
grant execute on function public.recover_stale_scoring_jobs(integer, interval) to service_role;

-- Re-invoke the scorer for jobs that are due. This is the half that was
-- missing: resetting a job to 'pending' means nothing if nobody ever picks
-- it up again, and the client that would normally invoke `score-run` is long
-- gone by the time a job goes stale.
create or replace function public.drive_pending_scoring_jobs(p_limit integer default 10)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    job record;
    driven integer := 0;
    fn_url text;
    service_key text;
begin
    -- Configured with:
    --   alter database postgres set app.functions_url = 'https://<ref>.supabase.co/functions/v1';
    --   alter database postgres set app.service_role_key = '<key>';
    -- Absent in local development, where there is no edge runtime to call —
    -- so this returns 0 rather than erroring every minute.
    fn_url := current_setting('app.functions_url', true);
    service_key := current_setting('app.service_role_key', true);
    if fn_url is null or service_key is null then
        return 0;
    end if;

    for job in
        select id, run_id
          from public.scoring_jobs
         where status = 'pending'
           and next_attempt_at <= now()
         order by next_attempt_at
         limit least(greatest(p_limit, 1), 100)
    loop
        perform extensions.net.http_post(
            url := fn_url || '/score-run',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || service_key
            ),
            body := jsonb_build_object('runId', job.run_id, 'source', 'sweeper')
        );
        driven := driven + 1;
    end loop;
    return driven;
end;
$$;

revoke all on function public.drive_pending_scoring_jobs(integer) from public, anon, authenticated;
grant execute on function public.drive_pending_scoring_jobs(integer) to service_role;

-- Replace the old schedule so both halves run: reset what is stuck, then
-- actually push the queue forward.
select cron.unschedule('recover-stale-scoring-jobs')
 where exists (select 1 from cron.job where jobname = 'recover-stale-scoring-jobs');

select cron.schedule(
    'recover-stale-scoring-jobs',
    '* * * * *',
    $$select public.recover_stale_scoring_jobs(); select public.drive_pending_scoring_jobs();$$
);
