# Roadmap & Phase Ledger

> Living document. The ledger is updated at the end of every phase — it is the
> project's memory. Newest entries at the top of the log.

## Phase plan

Engine priority order is mandated by spec §86: telemetry → course validation →
run verification → scoring → leaderboards → ghosts → friends → custom courses →
sharing → subscriptions. UI is authored alongside but never blocks engine work.

| Phase | Scope | Status |
|---|---|---|
| **L0 Foundation** | Toolchains, Kit scaffold, migrations 0001–0002, pgTAP, docs, CI | ✅ done (2026-08-12) |
| **L1 Telemetry** | Fusion, orientation estimator, trajectory, events, simulator profiles | ✅ done (2026-08-12) |
| **L2 Courses** | Course model, checkpoints, validation, geometric map matching | ⚪ pending |
| **L3 Verification** | RunIntegrityEngine, cheat profiles, verdict matrix | ⚪ pending |
| **L4 Scoring + server** | ScoringEngine, sogen, score-run edge fn, TS ports, xval | ⚪ pending |
| **L5 Leaderboards** | leaderboard_entries, ranks, Smooooth Rating, achievements | ⚪ pending |
| **L6 Ghosts** | Ghost generation, gap math, privacy controls | ⚪ pending |
| **L7 Friends** | Friendships, challenges, invitations | ⚪ pending |
| **L8 Custom courses** | Creation, validation, publishing, reporting | ⚪ pending |
| **L9 Sharing** | Challenge codes, resolve-challenge, universal links (AASA) | ⚪ pending |
| **M1–M5 iOS layer** | project.yml, adapters, feature views, StoreKit — authored alongside L-phases | 🟡 ongoing |
| **M-final Mac session** | xcodegen, compile fixes, device sanity, StoreKit sandbox, TestFlight | ⚪ pending (needs a Mac) |

**Definition of done for every phase:** `make test` green (Kit + pgTAP + Deno +
syntax gate), docs updated, ledger entry added, work committed in small chunks.

## Ledger

### 2026-08-12 — L1 complete ✅ (136 Kit tests green)
- **VehicleOrientationEstimator**: gravity from quasi-static EMA; forward from
  GPS-corroborated acceleration windows (anchored ≥0.8 s — consecutive-fix
  dv/dt at 10 Hz is noise); property-tested under 20 random mounts.
- **TrajectoryProcessor + LocationConfidenceScorer**: 3-gate filtering
  (accuracy/monotonic-time/teleport), curve-based confidence (TS-port exact).
- **DrivingEventDetector**: speed-contextual thresholds — 0.4 g at 30 m/s is
  hardBraking, the same brake at 4 m/s is ordinary.
- **TelemetrySimulator**: all 12 spec §58 profiles; kinematic ground truth with
  corner-anticipating, jerk-aware speed follower; correlated (OU) GPS noise;
  honest ms clock jitter vs mockGPS's metronome clock; hairpin demo routes.
- **Pipeline integration suite** (spec §59): calibration recovers the actual
  simulated mount; fast+smooth has zero hard events while fast+aggressive
  trips them; mock GPS fails calibration; degraded GPS lowers confidence.
  The e2e tests caught 3 real modeling flaws before commit — see TELEMETRY.md.
- Migrations 0003–0004 (scoring_configs, courses+checkpoints) landed early
  with 24 new pgTAP tests (40 total).
- **Next: L2** — SOCourse engine (course model, validation, checkpoint
  matching, progress); then L3 integrity.

### 2026-08-12 — L0 complete ✅
- Full Linux gate green: `make test` = 37 Swift tests + 16 pgTAP tests + 2 Deno
  tests + iOS syntax gate + kit purity check.
- pgTAP surfaced a real security gap: CLI-created tables carry no client grants;
  fixed with **explicit column-level grants** — `rating`/`rating_tier` are now
  unwritable by clients even on their own row (test enforces it).
- M1 done alongside: `App/project.yml` (XcodeGen), entitlements (Sign in with
  Apple, applinks), `Products.storekit` (weekly/monthly/yearly), app entry point.
- CI authored: Linux jobs kit/db/edge/xval on every push; macOS iOS build
  nightly/manual only.
- **Next: L1 telemetry engine** — SOCore math, orientation estimator,
  trajectory processing, event detection, simulator profiles, golden fixtures.

### 2026-08-12 — L0 started
- Architecture approved (see plan + ADR-0001, ADR-0002).
- Toolchains installed on Linux: Swift 6.1.3 (Ubuntu 24.04), Supabase CLI 2.113, Deno 2.9.5.
- `SmoooothKit` scaffolded: 9 modules + `sogen` CLI, **37 tests passing** on Linux.
- Migrations 0001 (extensions) + 0002 (profiles, RLS, signup trigger) authored with 15 pgTAP assertions.
