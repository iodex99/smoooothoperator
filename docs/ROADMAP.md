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
| **L2 Courses** | Course model, checkpoints, validation, geometric map matching | ✅ done (2026-08-12) |
| **L3 Verification** | RunIntegrityEngine, cheat profiles, verdict matrix | ✅ done (2026-08-12) |
| **L4 Scoring + server** | ScoringEngine, sogen, score-run edge fn, TS ports, xval | ✅ done (2026-08-12) |
| **L5 Leaderboards** | leaderboard_entries + ranks + RatingEngine + achievements | ✅ done (2026-08-12) |
| **L6 Ghosts** | Ghost generation, gap math, privacy controls (Kit ✅ + DB ✅ + server ✅) | ✅ done (2026-08-12) |
| **L7 Friends** | Friendships + challenges + participants (DB, state machines) | ✅ done (2026-08-12) |
| **L8 Custom courses** | validate-course edge fn, shared rejection fixtures | ✅ done (2026-08-12) |
| **L9 Sharing** | Challenge codes, resolve-challenge (anon-safe), AASA content | ✅ done (2026-08-12) |
| **M1–M5 iOS layer** | project.yml/entitlements/.storekit + adapters + DriveSession binding + feature views + StoreKit + mock mode | ✅ authored, parse-gated (2026-08-12) |
| **M-final Mac session** | xcodegen, compile fixes, device sanity, StoreKit sandbox, TestFlight | ⚪ pending (needs a Mac) |

**Definition of done for every phase:** `make test` green (Kit + pgTAP + Deno +
syntax gate), docs updated, ledger entry added, work committed in small chunks.

## Ledger

### 2026-08-12 — Phase 1 engine + backend COMPLETE; iOS layer authored (225 Kit tests, 132 pgTAP, 29 Deno, e2e green)
- **DriveSession (SOSync)**: the app's core loop as a Linux-tested actor —
  idle→calibrating→ready→active(live ghost gap)→processing→finished.
  mockGPS can never calibrate; deviation reported; self-ghost gap ≈ 0.
- **RatingEngine**: difficulty-weighted best-window Smooooth Rating + tiers.
- **Migrations 0011–0012**: achievements; subscriptions mirror (clients can
  never self-report entitlement) + has_active_pro().
- **validate-course** (L8): Pro-gated, TS validator pinned by 12 shared
  contract fixtures — server rejects exactly what the client rejects.
- **resolve-challenge** (L9): anonymous share-link resolution, dead codes
  404 like unknown ones, zero geometry/coordinate leakage. AASA content in
  web/.well-known/.
- **iOS app layer authored** (17 files, parse-gated): SensorFeed,
  SupabaseAPI, RunUploader, StoreKit service, mock mode; all four tabs,
  safety gate, pre-flight checklist, minimal driving screen, result screen
  with provisional→authoritative handoff, paywall (App Store prices only),
  ghost privacy controls. First compile happens on a Mac (IOS-NOTES.md).
- **Remaining for launch:** Mac hardening session (compile + device truth +
  StoreKit sandbox + TestFlight), App Store Server Notifications webhook,
  home/explore server feeds, friend-flow API wiring in views, deploy to a
  Supabase cloud project. Engine-side Phase 1 (spec §§86-87 priorities
  1-10) is done and tested.

### 2026-08-12 — L4 complete ✅ + L5/L6/L7 DB layers (212 Kit tests, 122 pgTAP, 14 Deno, e2e green)
- **ScoringEngine** (configs/scoring/v1.json curves): spec §59 synthetic
  competition holds — fastSmooth > fastAggressive via smoothness (not pace),
  slowSmooth loses on pace alone, ordering stable across seeds.
- **Golden vectors**: 12 committed pairs pin the whole pipeline; regeneration
  only via deliberate `make regen-goldens`.
- **TypeScript port** (agent-built, human-verified): all 13 pipeline modules,
  zero deps; **xval green — Swift ≡ TS on 12/12 vectors, first run.**
  (Note: the TS port files landed inside the friendships commit f3d989f.)
- **score-run edge function**: claim → blob → sha256 → pipeline →
  `apply_run_result` (atomic: run fields + best-only leaderboard + ghost +
  job). **E2E test green** against the live local stack incl. idempotency.
- **Migrations 0005–0010**: runs/telemetry/scoring_jobs (client can never
  write a score), leaderboards + ranked view, ghosts with live privacy
  controls, friendships (state machine + friends-tier visibility upgrades),
  challenges (spec §69 state machine), scoring infra (bucket, geometry RPC,
  stale-job recovery cron).
- **GhostEngine (Kit)**: start-line-anchored, staging never counts, ≤200
  points, no coordinates (privacy-tested), self-gap ≡ 0.
- **Next**: RatingEngine + achievements (L5 Kit), SOSync upload queue,
  validate-course (L8), sharing/resolve-challenge (L9), subscriptions 0011,
  iOS M-track adapters/features.

### 2026-08-12 — L3 complete ✅ (180 Kit tests green)
- **RunIntegrityEngine**: full check suite → VERIFIED/QUESTIONABLE/INVALID.
  Design principles proven by tests: streak gating so isolated honest GPS
  jumps never accuse; mock detection needs ≥2 combined signatures; gyro↔GPS
  heading consistency catches scaled sensors without flagging aggressive
  driving; uncertainty never accuses (warning ⇒ questionable only).
- **Verdict matrix green**: 4 clean profiles verify (6-seed false-positive
  sweep), 3 cheat profiles invalid, degraded profiles questionable,
  routeDeviation invalid. gpsDrift documented as undetectable-in-v1.
- Matrix testing surfaced 2 real bugs: tracker off-course now judged against
  the whole course (progress still window-gated), open excursions at run end
  count; simulator course field made continuous.
- **Next: L4** — ScoringEngine + versioned config + sogen golden vectors +
  server path (migration 0005, score-run edge fn, TS ports, xval).

### 2026-08-12 — L2 complete ✅ (161 Kit tests green)
- **CourseMatcher**: local-ENU polyline projection with cursor-windowed
  matching — self-crossing/out-and-back courses can't snap to the wrong pass.
- **CourseValidator**: spec §25 rules, all limits configurable, reports every
  issue in one pass. Same rules get a TS port in `validate-course` (L8).
- **CourseProgressTracker**: monotone progress (never accrues off-course —
  corner-cutting buys nothing), in-order checkpoint gating, deviation grace,
  finish detection, `progressFraction` = the ghost axis (L6).
- Provider seams (`RoutingProvider`/`MapMatchingProvider`/`SpeedLimitProvider`)
  + deterministic fakes; v1 needs no external map vendor (cost control §90).
- Integration: clean sim profiles finish 4/4 gates; routeDeviation flagged;
  missingGPS cannot fake progress; demo course passes validation.
- DB side (0003–0004) landed earlier with 40 pgTAP tests.
- **Next: L3** — RunIntegrityEngine consuming L1/L2 signals → verdicts.

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
