-- 0028: "all its data" still did not mean all its data.
--
-- Migration 0024 fixed this once, for raw telemetry blobs. The same promise
-- was still false for a second reason, and it is worth writing down because
-- it is the same mistake: a cascade was trusted to mean deletion, and a
-- cascade only reaches what points AT you.
--
-- `courses.creator_id` references profiles ON DELETE SET NULL. So when a
-- driver deletes their account, the courses they created are not deleted —
-- they are ORPHANED. Verified against the running database:
--
--   Driven Public Course  | creator=NULL | public
--   My Private Road Home  | creator=NULL | private
--   Friends Only Lane     | creator=NULL | friends
--
-- The first one is fine, and deliberately so. Other people have driven it;
-- their runs, leaderboard entries and ghosts all reference it, and
-- `runs.course_id` is ON DELETE RESTRICT precisely so one person leaving
-- cannot erase everyone else's records. Anonymous community content is the
-- right outcome there.
--
-- The other two are not fine. Nobody ever drove them. With creator_id NULL,
-- a private course matches no visibility rule for any user and a friends
-- course has nobody to be friends with, so both are invisible to every
-- account forever — while the rows persist, holding the full geometry of a
-- road the person drove, which for a course built by recording a drive is
-- very often the road they live on.
--
-- Dead rows nobody can see, containing exactly the data the app said in
-- these words had been deleted:
--
--     "Your account and all its data have been deleted."
--
-- So: courses nobody has driven go with the account. Courses that carry
-- other people's history stay, anonymised, because those records belong to
-- the drivers who set them.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := (select auth.uid());
begin
    if me is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    -- Before the cascade, while creator_id still says who made them.
    -- Anything with a run against it is left alone: those runs are other
    -- drivers' records, and the ON DELETE RESTRICT on runs.course_id would
    -- refuse anyway. Checkpoints, ghosts, challenges and assignments all
    -- cascade from the course itself.
    delete from public.courses c
     where c.creator_id = me
       and not exists (select 1 from public.runs r where r.course_id = c.id);

    delete from auth.users where id = me;
end;
$$;

comment on function public.delete_my_account() is
    'Deletes the caller''s account, every row that cascades from it, and any '
    'course they created that nobody has driven. Courses that carry other '
    'drivers'' runs are kept and anonymised — those records are not the '
    'creator''s to erase. Does NOT remove telemetry blobs: storage tables '
    'refuse direct deletes, so the delete-account edge function clears those '
    'first and then calls this.';
