-- 0021: a course can no longer exist without a benchmark.
--
-- THE BUG. Pace is 35% of the score and is computed as
-- `duration / benchmark_seconds`. `ScoringEngine.paceScore` guards against a
-- zero benchmark by returning 0 — the safe thing numerically, and a silent
-- disaster for the driver: they lose a third of their score and are told
-- nothing about why.
--
-- `validate-course` inserts custom courses and never set a benchmark, so
-- EVERY user-created course scored zero pace, permanently. Custom courses
-- are a Pro feature, which made this a defect people paid for.
--
-- THE FIX. Derive it from the course's own geometry, in the database, so it
-- cannot be forgotten by a caller. A trigger is used rather than fixing the
-- edge function alone because the edge function is one of several paths in
-- and the next one would forget too.
--
-- WHAT THE NUMBER MEANS. It is a REFERENCE pace (spec §57), never a
-- fabricated human result and never anybody's actual time. It is a function
-- of distance and turn density only: more corners per kilometre means a
-- slower reference, because a twisty road is slower to drive well.

create or replace function public.derive_benchmark_seconds(
    p_distance_meters double precision,
    p_turn_count integer
)
returns integer
language sql
immutable
as $$
    -- Turn density, corners per kilometre.
    with density as (
        select case
            when p_distance_meters > 0
                then coalesce(p_turn_count, 0) / (p_distance_meters / 1000.0)
            else 0
        end as turns_per_km
    )
    select greatest(
        1,
        round(
            p_distance_meters / (
                -- 80 km/h on an open road, down to 45 km/h when the corners
                -- come thick and fast. The seeded catalog's own implied
                -- benchmark speeds span 45–88 km/h, so a derived course sits
                -- in the same range as a curated one rather than standing out.
                greatest(45.0, least(88.0, 80.0 - (select turns_per_km from density) * 3.0))
                / 3.6
            )
        )
    )::integer;
$$;

comment on function public.derive_benchmark_seconds(double precision, integer) is
    'Reference pace for a course, from geometry alone. Never a human result.';

create or replace function public.fill_course_benchmark()
returns trigger
language plpgsql
as $$
begin
    if new.benchmark_seconds is null then
        new.benchmark_seconds := public.derive_benchmark_seconds(
            new.distance_meters, new.turn_count
        );
    end if;
    return new;
end;
$$;

create trigger courses_fill_benchmark
    before insert or update of distance_meters, turn_count, benchmark_seconds
    on public.courses
    for each row
    execute function public.fill_course_benchmark();

-- Backfill anything already in the table. Without this the courses that
-- exist right now keep scoring zero pace forever.
update public.courses
   set benchmark_seconds = public.derive_benchmark_seconds(distance_meters, turn_count)
 where benchmark_seconds is null;

-- And make it structurally impossible from here on. The trigger fills it;
-- this makes a course that somehow slips past the trigger a loud failure
-- rather than a silent third of a score.
alter table public.courses
    add constraint courses_benchmark_present
    check (benchmark_seconds is not null and benchmark_seconds > 0)
    not valid;

-- `not valid` skips the scan of existing rows, which the backfill above has
-- already handled; validate now so the constraint is fully enforced.
alter table public.courses validate constraint courses_benchmark_present;
