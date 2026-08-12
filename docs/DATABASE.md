# Database

> Living document. One section per migration; updated whenever schema changes.

## Rules

1. **RLS is enabled in the same migration that creates a table.** No exceptions,
   no unprotected windows.
2. Every table's policies get pgTAP tests before the migration merges.
3. Raw telemetry is readable by its owner and the service role. Never anyone else.
4. Leaderboards/ghosts/profiles expose only deliberately public columns.
5. Only the service role writes competitive results (scores, ranks, verdicts) —
   a client can never insert `score = 99999`.

## Migrations

### 0001 — extensions
`postgis` (course geometry, checkpoint containment), `pgcrypto`, `pg_net` +
`pg_cron` (scoring-job sweep, used from L4). Also `public.set_updated_at()`
shared trigger function.

### 0002 — profiles
Public driver identity, 1:1 with `auth.users` via signup trigger
(`handle_new_user`, security definer, empty search_path). Username constrained
to `^[a-z0-9_]{3,20}$`, country to ISO alpha-2. Ghost privacy control column
(`ghost_visibility`: everyone/friends/nobody, spec §70).
Policies: world-readable (leaderboard + share-link identity), self-update only,
no direct insert/delete (trigger + auth cascade handle lifecycle).

### 0003 — scoring_configs
Versioned ScoringConfig JSON, semver-checked, partial unique index guarantees
at most one `active` row. World-readable (clients need it for provisional
scores); service-role-only writes. Config content lands in L4.

### 0004 — courses + course_checkpoints
PostGIS geography (linestring route, point start/finish/checkpoint centers,
GiST index). NULL `creator_id` = platform course. `benchmark_seconds` is a
reference benchmark, never a fabricated user record (spec §57). Client roles
are **read-only**: course creation goes exclusively through the validated
edge-function path (L8), so unvalidated geometry can never enter the catalog.
Visibility: active+public world-readable; creators see their own drafts and
private courses; `friends` visibility deliberately behaves as creator-only
until migration 0008 introduces friendships and replaces the policy.
Checkpoints inherit course visibility; radius constrained 5–500 m; unique
(course_id, sequence).

## Planned (from approved architecture)

| # | Tables | Phase |
|---|---|---|
| 0005 | runs, telemetry (pointer/envelope), scoring_jobs | L4 |
| 0006 | leaderboard_entries | L5 |
| 0007 | ghosts (normalized trajectory JSONB) | L6 |
| 0008 | friendships | L7 |
| 0009 | challenges, challenge_participants | L7 |
| 0010 | achievements | L5 |
| 0011 | subscriptions (App Store Server API mirror) | M4 |

## Telemetry storage decision (ADR-0002 context)

A 20-min run ≈ 72,000 samples (10 Hz GPS + 50 Hz IMU). As rows: ~20 MB and 72k
tuples per run — unaffordable. As gzip NDJSON in a private Storage bucket:
1.5–3 MB. The `telemetry` table stores the pointer + envelope (path, counts,
sha256, byte size, schema version); `runs` carries a ~1 Hz downsampled polyline
(~40 KB) so maps render without touching blobs. Ghosts store only normalized
(progress, elapsed) pairs — raw GPS never leaves the owner's run.

## Local development

```bash
supabase start -x studio,imgproxy,mailpit,logflare,vector,postgres-meta,edge-runtime,realtime
supabase test db   # pgTAP
```
