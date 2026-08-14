-- 0023: take back the privileges no client has ever needed.
--
-- Supabase's platform default (`pg_default_acl`) grants `anon` and
-- `authenticated` the full privilege set on every new table in `public` —
-- including TRUNCATE, REFERENCES, TRIGGER and MAINTAIN. Verified on this
-- database: a signed-in role can run
--
--     truncate table public.courses cascade;
--
-- successfully. TRUNCATE **bypasses row-level security entirely**, so every
-- policy in this schema is irrelevant to it, and CASCADE would take runs,
-- leaderboard entries and ghosts with the catalog.
--
-- It is not reachable today: PostgREST exposes no TRUNCATE verb, and an
-- unfiltered DELETE is refused. This is a latent hole, not a live one.
-- Closing it anyway, because "no route to it right now" is the reasoning
-- that ages worst — the next feature that runs SQL on a user's behalf, or
-- any future exposure, inherits a schema where a client can drop every
-- table's contents.
--
-- The project already grants columns explicitly rather than relying on
-- defaults. This finishes that posture for the privileges that were never
-- asked for.

do $$
declare
    table_name text;
begin
    for table_name in
        -- Tables AND views. A view cannot be truncated, but the grant is
        -- still there and the rule is "clients hold what they need, and
        -- nothing else" — a partial sweep is the kind that gets re-broken.
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind in ('r', 'v', 'm')
    loop
        -- SELECT / INSERT / UPDATE / DELETE are left exactly as each
        -- migration set them; only the privileges no client uses go.
        execute format(
            'revoke truncate, references, trigger on public.%I from anon, authenticated',
            table_name
        );
    end loop;
end;
$$;

-- And stop the default from re-granting them on every table added from here,
-- which is what made this schema-wide rather than a one-table mistake.
alter default privileges in schema public
    revoke truncate, references, trigger on tables from anon, authenticated;
