-- 0035: raw telemetry does not need to be kept forever, and keeping it is
-- both the largest line on the bill and the largest thing to lose.
--
-- A drive's raw trace is ~2.5 MB compressed (it was ~20 MB before the
-- uploader started gzipping) and it dominates everything else this product
-- stores by three orders of magnitude. It is also the most sensitive thing
-- here: a precise record of where somebody drove and how, usually starting
-- at their home.
--
-- WHAT IT IS ACTUALLY FOR, which is what decides the window. Two things:
-- re-scoring a run when the pipeline changes, and investigating a run whose
-- verdict is disputed. Both happen within days. Nothing in the product reads
-- a ninety-day-old blob — the run row, its sub-scores, its ghost and its
-- preview polyline are all derived at scoring time and kept forever.
--
-- So: ninety days, then the blob goes and the envelope stays. The envelope
-- is the honest record that the data existed and what its hash was; deleting
-- the row too would make a scored run look like it was never backed by
-- anything.
--
-- WHAT IS DELIBERATELY NEVER PURGED:
--   * a run that has not reached a terminal state — the blob is the only
--     copy of a drive that has not been scored yet, and a queue that is
--     stuck for three months is a bug to fix, not a drive to destroy;
--   * a run flagged for review, for as long as it is flagged.
--
-- The blobs themselves cannot be deleted from SQL: Supabase guards
-- storage.objects with a trigger that refuses direct deletes and points at
-- the Storage API. So this migration owns the BOOKKEEPING — which blobs are
-- due, and which have gone — and the `purge-telemetry` edge function does
-- the deleting. The row is marked only after the object is actually gone,
-- so a failure halfway leaves work to redo rather than a lie in the table.

alter table public.telemetry
    add column if not exists purged_at timestamptz;

comment on column public.telemetry.purged_at is
    'When the raw blob was deleted under the retention policy. The envelope '
    '(hash, counts, path) is kept: it is the record that the data existed.';

-- Only ever set by the purge function, never by a client. The column-level
-- grants on this table are already select+insert for `authenticated`, so no
-- client can write it; this makes that explicit for the new column.
revoke update on public.telemetry from authenticated;

-- ── The retention window ──────────────────────────────────────────────────
-- A setting rather than a literal so it can be changed without a migration,
-- and read back by the health panel and the tests.
create table if not exists public.retention_policy (
    id boolean primary key default true check (id),
    telemetry_days integer not null default 90
        check (telemetry_days between 7 and 3650),
    updated_at timestamptz not null default now()
);

insert into public.retention_policy (id) values (true)
on conflict (id) do nothing;

alter table public.retention_policy enable row level security;
grant select on public.retention_policy to authenticated;
grant all on public.retention_policy to service_role;

-- The window is not a secret and the app may want to state it ("raw sensor
-- data is deleted after 90 days"), so it is readable. It is not writable.
create policy "anyone may read the retention window"
    on public.retention_policy for select
    to authenticated
    using (true);

-- ── Which blobs are due ───────────────────────────────────────────────────
create or replace function public.telemetry_due_for_purge(batch_size integer default 100)
returns table (telemetry_id uuid, storage_path text)
language sql
security definer
set search_path = ''
as $$
    select t.id, t.storage_path
      from public.telemetry t
      join public.runs r on r.id = t.run_id
     where t.purged_at is null
       -- Terminal states only. A run still queued, processing, or failed
       -- may yet need its blob.
       and r.status = 'scored'
       and coalesce(r.completed_at, r.created_at)
           < now() - make_interval(days => (
               select p.telemetry_days from public.retention_policy p where p.id
           ))
     order by coalesce(r.completed_at, r.created_at)
     limit batch_size;
$$;

revoke all on function public.telemetry_due_for_purge(integer) from public, anon, authenticated;
grant execute on function public.telemetry_due_for_purge(integer) to service_role;

-- ── Recording that a blob is gone ─────────────────────────────────────────
-- Called only after the Storage API has confirmed the delete. Idempotent:
-- re-marking an already-purged row is a no-op rather than an error, because
-- a retry after a half-finished batch is the normal case.
create or replace function public.mark_telemetry_purged(ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    marked integer;
begin
    update public.telemetry t
       set purged_at = now()
     where t.id = any(ids)
       and t.purged_at is null;
    get diagnostics marked = row_count;
    return marked;
end;
$$;

revoke all on function public.mark_telemetry_purged(uuid[]) from public, anon, authenticated;
grant execute on function public.mark_telemetry_purged(uuid[]) to service_role;

-- ── Surfacing it ──────────────────────────────────────────────────────────
-- `admin_health` exists because the failures that matter here are the quiet
-- ones. A purge that stops running is exactly that: nothing breaks, no error
-- is raised, and the storage bill grows for months. So the backlog is a
-- health signal, not a statistic.
create or replace function public.telemetry_purge_backlog()
returns table (due_count bigint, oldest_due timestamptz)
language sql
security definer
set search_path = ''
as $$
    select count(*)::bigint,
           min(coalesce(r.completed_at, r.created_at))
      from public.telemetry t
      join public.runs r on r.id = t.run_id
     where t.purged_at is null
       and r.status = 'scored'
       and coalesce(r.completed_at, r.created_at)
           < now() - make_interval(days => (
               select p.telemetry_days from public.retention_policy p where p.id
           ));
$$;

revoke all on function public.telemetry_purge_backlog() from public, anon, authenticated;
grant execute on function public.telemetry_purge_backlog() to service_role;

create index if not exists telemetry_unpurged_idx
    on public.telemetry (run_id)
 where purged_at is null;

-- ── Running it ────────────────────────────────────────────────────────────
-- Daily, not hourly: the window is ninety days, so nothing is urgent, and a
-- batch of 100 blobs is a real amount of storage traffic. 03:20 UTC is off
-- the hour deliberately — every scheduler in the world fires on the hour.
--
-- Same shape as the scoring sweeper: absent settings mean local development,
-- where there is no edge runtime to call, so it returns 0 rather than
-- erroring once a day forever.
create or replace function public.run_telemetry_purge()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    fn_url text;
    service_key text;
    due integer;
begin
    fn_url := current_setting('app.functions_url', true);
    service_key := current_setting('app.service_role_key', true);
    if fn_url is null or service_key is null then
        return 0;
    end if;

    select count(*) into due from public.telemetry_due_for_purge(1);
    if due = 0 then
        return 0;
    end if;

    perform extensions.net.http_post(
        url := fn_url || '/purge-telemetry',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || service_key
        ),
        body := jsonb_build_object('source', 'cron')
    );
    return 1;
end;
$$;

revoke all on function public.run_telemetry_purge() from public, anon, authenticated;
grant execute on function public.run_telemetry_purge() to service_role;

select cron.unschedule('purge-expired-telemetry')
 where exists (select 1 from cron.job where jobname = 'purge-expired-telemetry');

select cron.schedule(
    'purge-expired-telemetry',
    '20 3 * * *',
    $$select public.run_telemetry_purge()$$
);
