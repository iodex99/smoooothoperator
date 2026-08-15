-- 0031: the text columns a client can write, and how big they may be.
--
-- Most were already bounded, and sensibly: username is `^[a-z0-9_]{3,20}$`,
-- display_name 40, vehicle name/make/model 40, challenge name 80, country
-- `^[A-Z]{2}$`. Three were not bounded by anything at all:
--
--   profiles.avatar_url   -- and NOTHING in the product reads it. Not the
--                            app, not the console, not an edge function. A
--                            column any account may write, without limit,
--                            that nobody ever looks at.
--   runs.device_id        -- an identifier, used as anti-cheat attestation
--   telemetry.sha256      -- a hash, which has exactly one length
--
-- No injection here — the app is SwiftUI and the console escapes now — but
-- an unbounded write on a free-to-create account is storage somebody else
-- pays for, and a hash column that accepts a novel is a hash column that is
-- not being checked.
--
-- The guard in 0028_bounded_text_test.sql asserts the SET of unbounded
-- user-writable text columns is empty, so the next one fails the build.
-- avatar_url is kept rather than dropped: it is unused, but a column is
-- cheap and guessing that nobody wants avatars later is not this
-- migration's call to make.

alter table public.profiles
    add constraint profiles_avatar_url_length
    check (avatar_url is null or char_length(avatar_url) <= 500);

alter table public.runs
    add constraint runs_device_id_length
    check (device_id is null or char_length(device_id) <= 200);

-- SHA-256 is 64 lowercase hex characters. Anything else is not a hash, and
-- the whole point of storing it is that the server re-checks the blob it
-- scores against the blob that was uploaded.
alter table public.telemetry
    add constraint telemetry_sha256_format
    check (sha256 is null or sha256 ~ '^[a-f0-9]{64}$');

-- The trigger already pins the shape of a telemetry path to the run owner's
-- prefix, but its regex ends in `+` — unbounded. A storage key is a key.
alter table public.telemetry
    add constraint telemetry_storage_path_length
    check (char_length(storage_path) <= 300);
