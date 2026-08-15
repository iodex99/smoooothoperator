-- 0032: a driver could make a course and never unmake it.
--
-- There is no DELETE policy on `public.courses` — not a restrictive one, none
-- at all — and nothing in the app ever sets `status` to 'archived' or
-- 'removed' either, though both values exist in the check constraint. So a
-- course, once created, was permanent.
--
-- That was tolerable while the catalog was 397 rows the project shipped.
-- It stopped being tolerable when drivers could create courses, because a
-- custom course is made by recording a drive: the course line IS a road the
-- creator drove, and it very often starts where they set off from. The
-- privacy policy now says that in as many words. Telling someone to think
-- carefully because it cannot be undone, while having the power to let them
-- undo it, is not a policy — it is an excuse.
--
-- Two outcomes, because a course is not always only its creator's:
--
--   NOBODY HAS DRIVEN IT  -> deleted outright. It is theirs alone, and the
--                            gates, ghosts and assignments cascade with it.
--
--   OTHERS HAVE DRIVEN IT -> archived. It leaves the catalog immediately
--                            (browse filters status='active'), and every run,
--                            record and ghost on it survives. `runs.course_id`
--                            is ON DELETE RESTRICT precisely so one person
--                            cannot erase what other people drove; this
--                            respects that rather than fighting it.
--
-- Same rule delete_my_account uses, for the same reason.

create or replace function public.delete_my_course(p_course uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := (select auth.uid());
    mine boolean;
    driven boolean;
begin
    if me is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    -- Ownership is read here, from the row, and never taken from the caller.
    select (c.creator_id = me) into mine
      from public.courses c where c.id = p_course;

    if mine is null then
        raise exception 'course not found' using errcode = 'P0002';
    end if;
    if not mine then
        -- Deliberately the same error as "not found": whether a course the
        -- caller cannot touch exists is not theirs to learn.
        raise exception 'course not found' using errcode = 'P0002';
    end if;

    select exists (select 1 from public.runs r where r.course_id = p_course)
      into driven;

    if driven then
        update public.courses
           set status = 'archived'
         where id = p_course;
        return 'archived';
    end if;

    delete from public.courses where id = p_course;
    return 'deleted';
end;
$$;

comment on function public.delete_my_course(uuid) is
    'Removes a course the caller created. Deleted outright when nobody has '
    'driven it; archived out of the catalog when they have, so their runs '
    'and records survive. Refuses anything the caller did not create, with '
    'the same error as a course that does not exist.';

revoke all on function public.delete_my_course(uuid) from public, anon;
grant execute on function public.delete_my_course(uuid) to authenticated;
