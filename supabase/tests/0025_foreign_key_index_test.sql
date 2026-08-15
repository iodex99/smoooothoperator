-- A foreign key with no index on the referencing side turns every delete of
-- a parent row into a full scan of the child table, while holding row locks.
-- Seven of them existed before this test did, on paths a driver actually
-- takes: deleting a car from the garage scanned both `runs` and
-- `leaderboard_entries`.
--
-- This is a guard, not an example. It asserts the set is EMPTY, so the next
-- foreign key added without an index fails the build instead of being found
-- later by someone measuring.

begin;
select plan(2);

select is(
    (select coalesce(string_agg(
        c.conrelid::regclass::text || '.' || (
            select string_agg(a.attname, ',' order by k.ord)
              from unnest(c.conkey) with ordinality k(att, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.att
        ), ', ' order by c.conrelid::regclass::text), '')
       from pg_constraint c
      where c.contype = 'f'
        and c.connamespace = 'public'::regnamespace
        -- An index serves a foreign key only if the FK columns are its
        -- LEADING columns. leaderboard_entries(course_id, user_id) cannot
        -- answer a user_id lookup, which is how that one hid.
        and not exists (
            select 1 from pg_index i
             where i.indrelid = c.conrelid
               and (string_to_array(i.indkey::text, ' '))[1:cardinality(c.conkey)]
                   = (select array_agg(x::text order by ord)
                        from unnest(c.conkey) with ordinality t(x, ord))
        )
    ),
    '',
    'every foreign key has an index on its referencing columns'
);

-- The one that cost the most, asserted by name so the intent survives even
-- if the generic check above is ever weakened.
select ok(
    exists (
        select 1 from pg_indexes
         where tablename = 'runs' and indexdef like '%(vehicle_id)%'
    ),
    'deleting a car from the garage does not scan every run ever driven'
);

select * from finish();
rollback;
