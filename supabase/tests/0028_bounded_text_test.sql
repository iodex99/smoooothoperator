-- Every text column a client can write is a column a client can fill.
--
-- This is a guard, not a list. It asserts the SET of unbounded
-- user-writable text columns is EMPTY, so a column added later without a
-- bound fails here rather than being found by whoever is paying the storage
-- bill. profiles.avatar_url was one of these, unbounded and writable by any
-- account, and read by nothing in the entire product.

begin;
select plan(4);

select is(
    (select coalesce(string_agg(distinct g.table_name || '.' || g.column_name, ', '
                                order by g.table_name || '.' || g.column_name), '')
       from information_schema.role_column_grants g
       join information_schema.columns c
         on c.table_schema = g.table_schema
        and c.table_name = g.table_name
        and c.column_name = g.column_name
      where g.table_schema = 'public'
        and g.grantee in ('anon', 'authenticated')
        and g.privilege_type in ('INSERT', 'UPDATE')
        and c.data_type in ('text', 'character varying')
        -- Bounded by the type itself.
        and c.character_maximum_length is null
        -- ...or by any CHECK constraint that names the column. A regex like
        -- '^[a-z0-9_]{3,20}$' and a char_length ceiling both count; an enum
        -- list counts too, since it admits only fixed strings.
        and not exists (
            select 1
              from pg_constraint con
              join pg_attribute a
                on a.attrelid = con.conrelid
               and a.attnum = any (con.conkey)
             where con.contype = 'c'
               and con.conrelid = ('public.' || quote_ident(g.table_name))::regclass
               and a.attname = g.column_name
        )),
    '',
    'every text column a client can write has a CHECK bounding what may go in it'
);

-- ── the three that were not, exercised against real rows ─────────────────

insert into auth.users (id, email)
values ('b0000001-0000-4000-8000-000000000001', 'bounded@test.local');

insert into public.courses (
    id, name, country, distance_meters, difficulty, turn_count,
    geometry, start_point, finish_point, status
) values (
    'b0000010-0000-4000-8000-000000000010', 'Bounded Road', 'ZZ', 4000, 3, 12,
    extensions.st_setsrid(extensions.st_makeline(
        extensions.st_makepoint(-174.5, -57.5),
        extensions.st_makepoint(-174.4, -57.5)), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-174.5, -57.5), 4326)::extensions.geography,
    extensions.st_setsrid(extensions.st_makepoint(-174.4, -57.5), 4326)::extensions.geography,
    'active'
);

insert into public.runs (id, user_id, course_id, status, started_at, completed_at)
values ('b0000020-0000-4000-8000-000000000020', 'b0000001-0000-4000-8000-000000000001',
        'b0000010-0000-4000-8000-000000000010', 'uploaded', now(), now());

select throws_ok(
    $$ update public.profiles set avatar_url = repeat('x', 501)
        where id = 'b0000001-0000-4000-8000-000000000001' $$,
    '23514',
    null,
    'avatar_url cannot be filled without limit — nothing in the product '
    'even reads it'
);

-- The storage path must satisfy the owner-prefix trigger first, so this
-- reaches the sha256 CHECK rather than tripping over the trigger.
select throws_ok(
    $$ insert into public.telemetry
           (run_id, storage_path, sha256, gps_count, imu_count, byte_size)
       values ('b0000020-0000-4000-8000-000000000020',
               'b0000001-0000-4000-8000-000000000001/blob.ndjson.gz',
               'not-a-hash', 1, 1, 1) $$,
    '23514',
    null,
    'a sha256 column that accepts a novel is a hash nobody is checking'
);

select ok(
    exists (select 1 from pg_constraint
             where conrelid = 'public.runs'::regclass
               and conname = 'runs_device_id_length'),
    'device_id is an identifier, and identifiers have a length'
);

select * from finish();
rollback;
