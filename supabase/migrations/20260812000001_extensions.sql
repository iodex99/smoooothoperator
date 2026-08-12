-- 0001: Database extensions.
-- postgis: course geometry, checkpoint containment, distance validation.
-- pgcrypto: gen_random_uuid() and hashing.
-- pg_net + pg_cron: async re-invocation sweep for the scoring job queue (L4).

create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- Shared trigger function: keep updated_at honest on every table that has one.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
