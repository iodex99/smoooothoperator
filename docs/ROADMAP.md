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
| **M-final Mac session** | ~~compile fixes~~ ✅ compiles + boots in Simulator on CI Mac (2026-08-13); remaining: device sensor truth, StoreKit sandbox, TestFlight | 🟡 CI-verified |

**Definition of done for every phase:** `make test` green (Kit + pgTAP + Deno +
syntax gate), docs updated, ledger entry added, work committed in small chunks.

## Ledger

### 2026-08-13 — The last mile: sign-in, and the features that were missing
- **Sign in with Apple** (the audit's #1 blocker). Hashed-nonce challenge,
  Keychain session (ThisDeviceOnly), token refresh with one retry on 401,
  and signing in immediately flushes the offline run queue. Optional by
  design: the app drives, scores and queues signed out.
- **Run history + real records.** The app recorded every drive and had
  nowhere to show them; Profile's rating/wins/top-10 were hardcoded zeros.
- **Ghost racing now genuinely ships** — the course screen fetches the best
  ghost the privacy rules allow and hands it to DriveView, lighting up a
  live gap readout that had been dead code.
- **Friends works.** Send/accept/decline/remove were empty function bodies.
- **App Store Server Notifications V2**, fail-closed: JWS signature +
  pinned Apple root CA, 503 rather than trusting an unverifiable payload.
  Without it the server never learned about subscriptions and refused
  *paying* users the one Pro feature.
- A second sweep for genuinely-missing features found the worst remaining
  hole: **a new user could not grant location anywhere in the app**, so
  Home dead-ended on first launch. Fixed, along with: no way to set a
  username (everyone was `driver_8f3a1c9e2b7d`), missing OpenStreetMap
  attribution (an ODbL obligation), a paywall still selling custom courses,
  and raw internal reason codes leaking into user-facing copy.
- See **docs/OPERATIONS.md** for where data lives, setup, and costs.

### 2026-08-13 — Production-readiness audit: 4 domains, 40+ findings, criticals fixed
Four parallel adversarial reviews (data/server, iOS completeness, engine,
monetization/compliance) against the live stack and the real code. Full
report: **docs/AUDIT-2026-08-13.md**. What the audit changed:

- **The docs were ahead of the code and the UI was lying.** ARCHITECTURE.md
  and TELEMETRY.md described an offline upload queue that did not exist;
  RunResultView told users "Your run is safely stored" while the finished
  drive lived only in a SwiftUI @State and was destroyed on dismiss. Built
  for real: PendingRun/RunStore/UploadQueue with enqueue-before-network,
  crash recovery, corruption quarantine and capped backoff (10 tests).
- **A remote-triggered fleet crash.** One malformed row in `scoring_configs`
  would SIGILL every client at the end of every drive (precondition on
  weight validity + the client decoding the config raw). Now degrades.
- **Two security holes.** score-run authenticated nobody and checked no
  ownership (any user could read another's score + anti-cheat flags);
  `telemetry.storage_path` was unvalidated and interpolated into a
  service-role storage URL (traversal accepted live). Both closed, plus a
  runs.status transition guard, the missing friends branch on checkpoint
  RLS, and verified-only participant counts.
- **A NaN GPS fix voided whole runs** (0 m, 0 gates) — no finiteness gate.
- **The app was unusable in a Release build**: the only course path was
  `#if DEBUG`, so the primary CTA led to a permanent spinner. And the drive
  screen could trap a driver with no exit when location was denied.
- **The subscription sold nothing**: `hasPro()` had zero call sites. There
  is now a real free tier (3 runs/day) and the paywall sells only what
  exists — ghost racing was being sold and is not implemented.
- Fixed too: leaderboards mixing every course into one "rank 1" list,
  account deletion as an empty closure, ghost privacy that never persisted.

**Ledger correction:** earlier entries marked the L-phases complete while
SOSync's upload queue was never built. Status claims in this file now track
what is wired into the app, not what is authored in the Kit.

### 2026-08-13 — Today's Challenge: dynamic location-based assignment
- No more hand-authored daily challenges: `today-challenge` edge fn finds
  eligible courses near the user (radius ladder 10/25/50/100 km), ranks
  them deterministically (proximity/quality/freshness/friend activity/
  participation/format fit — env-configurable weights), assigns per the
  user's LOCAL date, and returns a drive-ready payload. See
  docs/CHALLENGES.md.
- New: migration 0013 (`challenge_assignments` + `challenge_candidates()`
  + `course_route()`), `_shared/challenge/` module, Home card states
  (format + tagline, real participants, your/friend best, first-record,
  coming-soon/unavailable). Formats are a registry — SMOOTH_SPRINT ships,
  others are an entry away. Existing scoring untouched.
- Tests: +16 pgTAP, +16 Deno unit, +1 nine-scenario stack integration
  (per-run isolated geography). Sequencing all suites surfaced two latent
  residue bugs (unscoped 0008 asserts, creator-less e2e courses) — fixed.

### 2026-08-13 — Full product pass: drive map, onboarding, app icon
- **Drive map** (user directive: "the driver would need to have a look at
  the map for the next turns"): heading-aligned follow-cam under the
  active-drive overlay — route ahead in white, covered course in heat,
  driver puck, camera re-aims every ~2% of course. Never interactive.
  Whole-course frame during calibration/ready. Also adds the previously
  missing **end-run escape hatch** (small, confirmed, "never submitted").
- **Onboarding** (spec §§76-77): five driver-paced pages — brand, the
  game, the 35/35/20/10 scoring split, verification + privacy promise,
  safety gate. Persists with the safety acknowledgement;
  SMOOOOTH_DEMO_ONBOARDING=1 auto-walks it for CI capture.
- **Install polish**: generated heat-route app icon (1024 single-size),
  launch-screen ground color (no white flash), home-screen name
  "Smooooth", score-reveal success haptic, Friends themed.

### 2026-08-13 — Heat design system: premium UI, map view, share card
- Full visual identity in `App/Sources/DesignSystem/` (user directive: the
  UI "shall look premium, rich, aesthetic"): near-black ground, blaze→amber
  **heat gradient** for brand/CTAs/rings/routes; green reserved strictly for
  verification semantics. GlowRing (score/rating), HeatBar (sub-scores),
  RoutePreview (tile-free glowing course trace — works offline, identical
  in cards/drive/share).
- New capability, not just paint: **course detail map view** (dark MapKit
  tiles, heat route polyline, start/finish gate markers) and a **rendered
  share card** (ImageRenderer @3×: score, course trace, wordmark — never
  raw location; spec §51 growth loop).
- Every screen restyled: Home hero challenge card, Explore route-thumbnail
  cards + filter chips, leaderboard podium medals, profile rating ring +
  Pro card, paywall, drive screen (route trace lights up with progress),
  result glow-ring reveal, safety gate.
- Demo tour v2 adds a 10s course-map stop before the mock drive; CI
  captures 48 frames.

### 2026-08-13 — The app runs: CI Mac builds, boots, and screenshots it
- One compile error existed across the entire blind-authored iOS layer
  (SensorFeed @Sendable capture). After the fix: xcodegen ✅ build ✅
  simulator install/launch ✅ — screenshot artifact shows the spec §77
  DRIVE SAFE gate rendering correctly in dark mode.
- Workflow accepts `main:ios-build` pushes (Codespace tokens can't
  dispatch); each run uploads simulator screenshots. Remaining untestable
  without hardware: real GPS/IMU truth, StoreKit sandbox, TestFlight.


### 2026-08-13 — Catalog doubled for revenue markets: 397 courses / 30 countries
- Doubling directive applied: US 53→106, GB 20→40, AU 17→33, DE 11→23,
  CH 11→22, CA 10→19, NZ 8→16, NO 7→14, AE/IE/SE/NL/DK all doubled.
  India intact at 30 (~8%% of catalog). ~13,000 km of validated road.
- Two triage rounds: 386/401 → fixes → 397/401; 4 persistent wrong-way/
  over-cap roads dropped and documented. pgTAP floors raised (total ≥360,
  US ≥80, GB ≥30); 141 db tests green. Seed: 2.5 MB.


### 2026-08-13 — Platform catalog expanded to 250 courses / 30 countries
- Revenue-market weighting per directive: US 53, GB 20, AU 17, IT 13,
  CH/DE/FR 11, CA 10, NZ 8 + 11 new countries (PT, BE, FI, SE, IS, ZA, HK,
  TW, KR, HR, CL). India holds 30. ~6,900 km of validated road.
- Final generation pass: 250/250 accepted, 0 rejects; pgTAP catalog floor
  raised to 220 with market-depth + 25-country assertions (141 db tests).


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
