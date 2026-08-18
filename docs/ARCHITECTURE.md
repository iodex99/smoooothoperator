# Architecture

> Living document. Updated whenever structure or a load-bearing decision changes.
> Decisions with alternatives considered live in [decisions/](decisions/).

## The one constraint that shapes everything

Primary development happens on **Linux** (Codespace). Xcode does not exist here,
so SwiftUI/CoreLocation/CoreMotion/StoreKit/SwiftData code cannot be compiled or
tested in this environment. Therefore:

**~90% of product logic lives in `SmoooothKit`, a pure-Swift SwiftPM package that
builds and tests green on Linux at every commit.** The iOS layer in `App/` is a
thin shell: SwiftUI layout + adapters that conform Apple frameworks to Kit
protocols. `tools/kit-purity-check.sh` mechanically forbids Apple-only imports
in the Kit; `tools/ios-syntax-check.sh` parse-gates the blind-authored iOS code.

## SmoooothKit module graph

```
SOCore ◄── SOModels ◄─┬─ SOTelemetry ◄─┬─ SOScoring   (also ◄── SOCourse)
                      │                ├─ SOIntegrity
                      │                └─ SOGhost     (also ◄── SOCourse)
                      ├─ SOCourse
                      └─ SOSync
SOSimulator ──► SOTelemetry, SOCourse, SOScoring, SOIntegrity, SOGhost
sogen (CLI) ──► SOSimulator, SOSync
```

| Module | Responsibility |
|---|---|
| `SOCore` | Geodesy primitives, seeded RNG, deterministic helpers. Zero dependencies. |
| `SOModels` | Codable domain models, DTOs, scoring weights/config types. |
| `SOTelemetry` | `LocationSource`/`MotionSource` seam, sensor fusion, `VehicleOrientationEstimator`, `TrajectoryProcessor`, `DrivingEventDetector`. |
| `SOCourse` | Course/checkpoint model, course validation, geometric map matching, `RoutingProvider`/`MapMatchingProvider`/`SpeedLimitProvider` protocols + fakes. |
| `SOScoring` | `ScoringEngine` (pace/smoothness/control/compliance → integer bps), `RatingEngine`. |
| `SOIntegrity` | `RunIntegrityEngine`: anti-cheat flags → verification verdict. |
| `SOGhost` | Normalized ghost trajectories, live gap math. Never raw GPS. |
| `SOSync` | Offline-first upload queue (PendingRun/RunStore/UploadQueue — durable, retrying, wired into the app since 2026-08-13), drive session state machine, entitlement seam. |
| `SOSimulator` | Synthetic driving profiles feeding the **same** pipeline as real sensors. |
| `sogen` | CLI: simulate / score / verify / emit golden vectors. |

**The most important seam:** `LocationSource`/`MotionSource` in `SOTelemetry`.
iOS adapters (CoreLocation/CoreMotion) and the simulator both conform to these;
everything downstream is identical for real and synthetic data (spec §58).

## The three deployment surfaces

1. **SmoooothKit** — engines, tested on Linux.
2. **App/** — iOS shell, generated with XcodeGen from `App/project.yml` on a Mac.
   All unverifiable iOS config (Info.plist keys, entitlements, StoreKit) is
   concentrated in that one reviewable YAML file.
3. **supabase/** — Postgres (RLS in the same migration as every table),
   edge functions (Deno). The server is authoritative for scores: the client's
   score is provisional; `score-run` re-validates and re-scores every upload.

## Server-authoritative scoring across two languages

Swift is the *reference* scorer; a TypeScript port in
`supabase/functions/_shared/scoring/` is the *operationally authoritative* one.
CI proves them identical on every golden vector (`make xval`). This is safe
because scoring math is restricted to `+ − × ÷ √` over piecewise-linear config
curves, and sub-scores are quantized to integer basis points **before** the
35/35/20/10 weighting — floating point never touches a final score.
See [SCORING.md](SCORING.md) and ADR-0002.

## Data flow of a run

```
sensors → raw telemetry (append-only file, crash-safe)
        → fusion → trajectory → map matching → events
        → provisional score (client, SmoooothKit)
        → gzip blob at sensor resolution → Storage (private bucket)
        → runs row (status=uploaded) → scoring_jobs queue
        → score-run edge fn: hash check → integrity → verdict → score
        → leaderboard_entries upsert (service role, one transaction)
```

Raw telemetry is never public, never destroyed by processing, and never leaves
the owner's control. It is deleted 90 days after the run is scored (migration
0035) — nothing in the product reads a blob after scoring, and it is the most
sensitive thing here. Ghosts expose only normalized (progress, elapsed-time)
pairs — see [ANTICHEAT.md](ANTICHEAT.md) and [DATABASE.md](DATABASE.md).
