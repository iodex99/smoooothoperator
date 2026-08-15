-- 0030: the telemetry bucket had no ceiling on anything.
--
-- Who may write there was already correct and tested: uploads are confined
-- to the caller's own uid prefix by a storage policy, and
-- `validate_telemetry_path` re-checks the prefix against the run's owner
-- when the pointer row is written. Reads and deletes are owner-only.
--
-- HOW MUCH they may write was unbounded. `file_size_limit` was NULL, so any
-- authenticated account could upload objects of any size, as many as it
-- liked, under a prefix it controls. Storage is billed by the gigabyte, so
-- an unbounded write path on a free-to-create account is a bill someone else
-- pays. Nothing in the product needs it.
--
-- The ceiling is derived from the engine's own limits rather than picked:
-- `DriveSessionConfig` caps one run at 100,000 GPS samples and 500,000 IMU
-- samples (themselves sized from the 2-hour run ceiling with headroom). At
-- roughly 100 bytes per sample uncompressed that is ~60 MB of raw NDJSON
-- before gzip, and a real 20-minute drive compresses to 1.5-3 MB. 64 MB is
-- therefore far above any legitimate run and far below a useful attack.
--
-- The mime type is pinned for the same reason it is pinned everywhere else:
-- a bucket that accepts anything is a file host.

update storage.buckets
   set file_size_limit = 67108864,  -- 64 MiB
       allowed_mime_types = array['application/octet-stream', 'application/gzip']
 where id = 'telemetry';
