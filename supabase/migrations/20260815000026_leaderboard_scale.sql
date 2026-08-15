-- 0026: the leaderboard was O(the whole product), and its ranks were wrong
-- on two of the three boards.
--
-- `course_leaderboards` computes rank with a window function:
--
--     row_number() over (partition by course_id order by score desc, ...)
--
-- A window function is evaluated before ORDER BY and LIMIT, so asking for
-- the top 50 sorts the entire partition first and throws away the rest.
-- Measured on this database with 20,000 entries on one course:
--
--     top 50 of a 20k board   47.8 ms   (sorts 20,000, joins 20,000 profiles)
--
-- That is O(entries on the course) to show a screenful, and it is the
-- screen the whole product competes on.
--
-- THE WORSE ONE. ProfileView asked for its ranks with no course filter at
-- all:
--
--     course_leaderboards?user_id=eq.<id>&select=rank
--
-- With nothing to partition-prune, the window runs over EVERY entry on
-- EVERY course, hash-joins EVERY profile, sorts the lot, and then discards
-- all but the caller's rows:
--
--     Rows Removed by Filter: 19999
--     Execution Time: 24.2 ms          -- to return ONE row
--
-- That is O(total entries in the entire product) on the profile screen. At
-- 20k rows it is 24 ms; the shape is what matters, because it only ever
-- goes one way.
--
-- AND THE RANKS WERE WRONG. The national and friends boards filter the view
-- by country / user id AFTER the global rank has been computed, so a
-- friends board with five people on it read
--
--     #4,912   #8,201   #15,043
--
-- instead of #1 to #5. Correctly ordered, meaninglessly numbered — and on a
-- friends board, the number IS the point. Ranking within the filtered set
-- is both the correct behaviour and, for the global board, the cheap one.
--
-- The view is kept: it is the honest definition of a rank, several pgTAP
-- tests read it, and it is fine for small sets. It is simply no longer what
-- the app calls.

-- ── the index the slice needs ─────────────────────────────────────────────
--
-- The old index stopped at (course_id, score desc), so the planner still had
-- to sort within equal scores. The full tie-break belongs in the index, and
-- then the top-N slice is a plain index scan that stops after N rows.

create index if not exists leaderboard_entries_rank_full_idx
    on public.leaderboard_entries (course_id, score desc, duration_seconds asc, created_at asc);

drop index if exists public.leaderboard_entries_rank_idx;  -- a prefix of the above

-- "which boards am I on" had no index at all. The unique index starts with
-- course_id, so it cannot answer a user_id-only lookup, and every question
-- the profile asks about a driver scanned the whole table to find their
-- handful of rows. That is the O(the product) term that survives fixing the
-- window function.
create index if not exists leaderboard_entries_user_idx
    on public.leaderboard_entries (user_id);

-- ── one page of a board, ranked within the board being shown ──────────────

create or replace function public.leaderboard_page(
    p_course uuid,
    p_country text default null,
    p_user_ids uuid[] default null,
    p_limit integer default 50,
    p_offset integer default 0
)
returns table (
    course_id uuid, user_id uuid, run_id uuid, score integer,
    duration_seconds integer, smoothness_bps integer, created_at timestamptz,
    rank bigint, username text, display_name text, country text
)
language sql
stable
security invoker
set search_path = ''
as $$
    with bounds as (
        select least(greatest(coalesce(p_limit, 50), 1), 100) as lim,
               greatest(coalesce(p_offset, 0), 0) as off
    ),
    -- The slice is taken BEFORE any window function runs. This is the whole
    -- point: with the index above, an unfiltered board reads exactly
    -- lim+off rows instead of the entire partition.
    slice as (
        select e.course_id, e.user_id, e.run_id, e.score,
               e.duration_seconds, e.smoothness_bps, e.created_at
          from public.leaderboard_entries e
         where e.course_id = p_course
           -- A filtered board has to consult profiles to filter at all, so
           -- these two paths cost what they cost. They are still bounded by
           -- one course, and they are the ones that were mis-numbered.
           and (p_user_ids is null or e.user_id = any (p_user_ids))
           and (
               p_country is null
               or exists (
                   select 1 from public.profiles p
                    where p.id = e.user_id and p.country = p_country
               )
           )
         order by e.score desc, e.duration_seconds asc, e.created_at asc
         limit (select lim from bounds) offset (select off from bounds)
    )
    select s.course_id, s.user_id, s.run_id, s.score,
           s.duration_seconds, s.smoothness_bps, s.created_at,
           (select off from bounds) + row_number() over (
               order by s.score desc, s.duration_seconds asc, s.created_at asc
           ) as rank,
           p.username, p.display_name, p.country
      from slice s
      join public.profiles p on p.id = s.user_id
     order by rank;
$$;

comment on function public.leaderboard_page(uuid, text, uuid[], integer, integer) is
    'One page of a course leaderboard, ranked WITHIN the board requested — a '
    'friends board reads #1..#5, not the global ranks of those five people. '
    'The page is sliced before ranking, so an unfiltered board reads '
    'limit+offset rows rather than the whole partition.';

-- ── my rank on one course, without ranking anybody else ───────────────────
--
-- Counting the people ahead of you is O(people ahead of you) over the index,
-- rather than O(the board). Last place on a huge board is still the worst
-- case, but it is an index-only count rather than a sort plus a join.

create or replace function public.my_course_rank(p_course uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
    select 1 + (
        select count(*)
          from public.leaderboard_entries o
         where o.course_id = mine.course_id
           and (
               o.score > mine.score
               or (o.score = mine.score and o.duration_seconds < mine.duration_seconds)
               or (o.score = mine.score and o.duration_seconds = mine.duration_seconds
                   and o.created_at < mine.created_at)
           )
    )
      from public.leaderboard_entries mine
     where mine.course_id = p_course
       and mine.user_id = (select auth.uid());
$$;

-- ── the two numbers the profile actually wanted ───────────────────────────
--
-- The profile downloaded every rank it could see and counted the 1s and the
-- <=10s in Swift. It only ever needed two integers, and getting them this
-- way costs one round trip and no global sort.

create or replace function public.my_rank_summary()
returns table (wins bigint, top_ten bigint)
language sql
stable
security invoker
set search_path = ''
as $$
    select
        count(*) filter (where r = 1),
        count(*) filter (where r <= 10)
      from (
        select 1 + (
            select count(*)
              from public.leaderboard_entries o
             where o.course_id = mine.course_id
               and (
                   o.score > mine.score
                   or (o.score = mine.score and o.duration_seconds < mine.duration_seconds)
                   or (o.score = mine.score and o.duration_seconds = mine.duration_seconds
                       and o.created_at < mine.created_at)
               )
        ) as r
          from public.leaderboard_entries mine
         where mine.user_id = (select auth.uid())
      ) ranked;
$$;

grant execute on function public.leaderboard_page(uuid, text, uuid[], integer, integer)
    to anon, authenticated, service_role;
grant execute on function public.my_course_rank(uuid) to authenticated, service_role;
grant execute on function public.my_rank_summary() to authenticated, service_role;
