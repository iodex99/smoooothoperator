# Step 6's two settings cannot work as written

**Status: RESOLVED 2026-08-21.** Option A (Vault) implemented and applied as migration
`20260821000037_cron_config_from_vault.sql`. Both functions verified reading Vault,
neither reading the old GUC. One step remains: add the `service_role_key` secret.

**Originally:** blocked, needs a decision. Found 2026-08-21 while executing step 6.

---

## What the runbook says

```sql
alter database postgres set app.functions_url = 'https://<ref>.supabase.co/functions/v1';
alter database postgres set app.settings.service_role_key = '<service role key>';
```

Run "in the dashboard SQL editor."

## What actually happens

```
ERROR: 42501: permission denied to set parameter "app.functions_url"
```

Every route returns this:

| Route | Result |
| --- | --- |
| Dashboard SQL editor | `42501` |
| `supabase db query --linked` (Management API) | `42501` |
| `ALTER ROLE postgres SET ...` instead of `ALTER DATABASE` | `42501` |

The cause is visible in one query:

```sql
select current_user, usesuper from pg_user where usename = current_user;
--  postgres | false
```

`postgres` is **not** superuser on Supabase's managed platform. Persisting a custom
GUC via `ALTER DATABASE` or `ALTER ROLE` needs superuser or explicit
`GRANT SET ON PARAMETER`, and neither is available to us. This is not a typo or a
transient error — the step cannot succeed as written, by anyone, on this project.

## The second bug, which would have survived fixing the first

The migrations read:

```
supabase/migrations/20260814000020_scoring_job_recovery.sql:89
    fn_url      := current_setting('app.functions_url',   true);
supabase/migrations/20260814000020_scoring_job_recovery.sql:90
    service_key := current_setting('app.service_role_key', true);
supabase/migrations/20260818000035_telemetry_retention.sql:169
    fn_url      := current_setting('app.functions_url',   true);
supabase/migrations/20260818000035_telemetry_retention.sql:170
    service_key := current_setting('app.service_role_key', true);
```

The code reads **`app.service_role_key`**. The runbook tells you to set
**`app.settings.service_role_key`**. Different names.

`current_setting(name, true)` returns `NULL` on a missing setting rather than
raising. So even with superuser, following the runbook exactly would have set a
parameter nothing reads, and:

```sql
if fn_url is null or service_key is null then
    -- returns 0
```

...the sweeper returns `0`, reports success, and deletes nothing. Which is
precisely the failure mode `20260815000033_admin_health.sql` warns about:

> pending means the pg_cron sweeper is not running — which is a config
> problem (app.functions_url / app.service_role_key) that produces
> **exactly zero errors anywhere**, because the sweeper returns 0 rather
> than failing when unconfigured.

Two independent bugs, both silent, in the same step.

---

## Options

### A. Supabase Vault (recommended)

Vault is Supabase's supported mechanism for exactly this — secrets that pg_cron
and pg_net jobs need at runtime. Encrypted at rest, unlike a plain table.

```sql
-- once, by hand, values never entering version control:
select vault.create_secret('https://tsxyxgtjihycaoydyafp.supabase.co/functions/v1',
                           'functions_url');
select vault.create_secret('<service role key>', 'service_role_key');
```

Then in both migrations, replace the two `current_setting` calls with:

```sql
select decrypted_secret into fn_url
  from vault.decrypted_secrets where name = 'functions_url';
select decrypted_secret into service_key
  from vault.decrypted_secrets where name = 'service_role_key';
```

The `if ... is null then return 0` guard stays exactly as it is, so a missing
secret still degrades the same way — but now it is reachable.

**Verify `supabase_vault` is enabled first:**

```sql
select extname from pg_extension where extname = 'supabase_vault';
```

### B. A private settings table

Simpler, but stores the service-role key in plaintext in a table. Given that key
bypasses every RLS policy in the database, A is materially safer for the key.
This option is only worth it if Vault turns out not to be available.

### C. Inline the values into the cron job bodies

Rejected. It puts the service-role key into `cron.job` in plaintext, readable by
anything that can select from that table, and it has to be redone on every
re-schedule.

---

## Why this is not applied yet

Two reasons, both worth stating plainly:

1. **It changes two shipped migrations**, so it needs your call on mechanism
   before it goes in — this is a design decision about where your most
   privileged secret lives, not a typo fix.
2. **I could not test it.** The Codespace restarted and the Supabase CLI token
   went with it, so I have no database access to confirm Vault is enabled or that
   the rewritten functions run. Shipping an untested migration into
   `supabase/migrations/` would mean the next `db push` runs it blind.

Deliberately filed here in `docs/` rather than as a migration, so nothing
executes by accident.

## What to do

1. Pick A or B
2. Re-run `supabase login --no-browser`
3. Confirm the extension check above
4. I write the migration, push it, and verify the sweeper returns non-zero

## Verifying it actually worked

The whole point is that this step fails silently, so check it directly rather
than trusting a clean run:

```sql
-- should return a row, not zero rows
select * from cron.job;

-- after the next scheduled run, should show a completed run, not nothing
select status, return_message, start_time
  from cron.job_run_details order by start_time desc limit 5;
```
