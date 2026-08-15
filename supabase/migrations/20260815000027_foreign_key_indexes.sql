-- 0027: seven foreign keys with nothing to look them up by.
--
-- Postgres does not index the referencing side of a foreign key for you.
-- Every DELETE of a parent row then has to scan the whole child table to
-- prove no child references it — while holding row locks:
--
--   explain: select 1 from runs where vehicle_id = $1 for key share
--   ->  LockRows
--         ->  SEQ SCAN on runs
--
-- These are not obscure admin paths. They are things a driver does:
--
--   * DELETING A CAR FROM THE GARAGE scans `runs` AND `leaderboard_entries`
--     — the two largest tables in the product — because both reference
--     vehicles and neither indexed it.
--
--   * DELETING AN ACCOUNT scans `courses` (the whole catalog) for
--     creator_id, `friendships` for requester_id, and then, once per run
--     that cascades, `challenge_participants` for run_id. A driver with 500
--     runs pays that 500 times.
--
--   * DELETING A CUSTOM COURSE scans `challenge_assignments`.
--
-- Measured at 20,000 runs it is a few milliseconds, so nothing is on fire
-- today. The shape is what matters: it is O(the child table) per delete and
-- it only ever grows.
--
-- `0025_foreign_key_index_test.sql` asserts the set is empty, so the next
-- foreign key added without an index fails the build rather than waiting to
-- be found.

-- Deleting a car from the garage. Both of these also serve the natural
-- question "which runs / entries used this vehicle", which is what the
-- garage screen asks.
create index if not exists runs_vehicle_idx
    on public.runs (vehicle_id) where vehicle_id is not null;

create index if not exists leaderboard_entries_vehicle_idx
    on public.leaderboard_entries (vehicle_id) where vehicle_id is not null;

-- Deleting an account. creator_id is also read by the browse visibility
-- predicate, so this one earns its keep twice.
create index if not exists courses_creator_idx
    on public.courses (creator_id) where creator_id is not null;

-- The half of are_friends() that had no leading index. The planner copes
-- today by bitmap-ORing the addressee index twice, but the cascade on
-- account deletion has no such alternative.
create index if not exists friendships_requester_idx
    on public.friendships (requester_id, status);

-- Paid once per run when an account's runs cascade.
create index if not exists challenge_participants_run_idx
    on public.challenge_participants (run_id);

-- Deleting a custom course the creator no longer wants.
--
-- NOT named `challenge_assignments_course_idx`: that name is already taken
-- by an index on (user_id, course_id, created_at), which leads with user_id
-- and so cannot answer a course_id lookup. `create index if not exists`
-- matches on NAME, so the obvious name would have silently done nothing —
-- which is exactly what it did until the guard test failed.
create index if not exists challenge_assignments_course_fk_idx
    on public.challenge_assignments (course_id);

-- Scoring configs are never deleted, so this one buys nothing today. It is
-- here so the guard test can assert the set is EMPTY rather than "empty
-- except the ones we decided not to care about" — an allow-list is where
-- the next real one would hide.
create index if not exists runs_scoring_version_idx
    on public.runs (scoring_version);
