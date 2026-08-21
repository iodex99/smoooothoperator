-- Read pg_cron config from Vault instead of app.* GUCs.
-- postgres is not superuser on Supabase, so ALTER DATABASE/ROLE SET app.* fails
-- with 42501 and the settings could never be populated. Unconfigured, both
-- functions returned 0 with no error anywhere. See docs/BLOCKER-cron-config.md.

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
    fn_url := (select decrypted_secret from vault.decrypted_secrets where name = 'functions_url');
    service_key := (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key');
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
    fn_url := (select decrypted_secret from vault.decrypted_secrets where name = 'functions_url');
    service_key := (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key');
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
