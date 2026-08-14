-- 0024: account deletion, and the blobs the cascade cannot reach.
--
-- `delete_my_account` deletes `auth.users`, which cascades through profiles
-- → runs → the `telemetry` ROWS. Those rows are only pointers. The actual
-- files — every fix of every drive the person ever recorded, the most
-- sensitive data this product holds — stayed in the `telemetry` storage
-- bucket, orphaned and complete.
--
-- Meanwhile the app told them, in these words:
--
--     "Your account and all its data have been deleted."
--
-- That was not true, and a deletion that leaves someone's complete location
-- history behind is worse than not offering the button at all.
--
-- The blobs CANNOT be removed from here. Supabase protects the storage
-- tables with a trigger that refuses direct deletes and directs callers to
-- the Storage API:
--
--     Direct deletion from storage tables is not allowed.
--     Use the Storage API instead.
--
-- So the cleanup lives in the `delete-account` edge function, which clears
-- the objects FIRST and only then calls this. The order matters: after the
-- cascade there are no telemetry rows left to find the files by.
--
-- This function keeps its single job — the database half — and its comment
-- now says so, rather than leaving the next reader to assume it is the whole
-- of deletion. That assumption is what made the app's promise false.

comment on function public.delete_my_account() is
    'Deletes the caller''s account and every row that cascades from it. '
    'Does NOT remove telemetry blobs: storage tables refuse direct deletes, '
    'so the delete-account edge function clears those first and then calls '
    'this. Calling this alone leaves the raw GPS traces behind.';
