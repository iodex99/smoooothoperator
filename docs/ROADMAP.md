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

### 2026-08-18 — The 4,000× line: telemetry compressed, and no longer kept forever
Raw telemetry dominates everything else this product stores by about
4,000×, and both things OPERATIONS.md had listed as "to do before that
becomes a bill" were still undone. The uploader sent raw JSON — even though
`score-run` had accepted gzip transparently all along — and nothing ever
deleted a blob.

- **6.7× smaller, measured** (2,052,197 → 307,638 bytes on a real simulated
  drive). **Two thirds of that is not gzip.** Gzip alone gives 2.4×, not the
  8× the doc assumed, because a `Double` serialises to seventeen significant
  digits and the trailing ones are floating-point residue — the worst
  possible input to a compressor. Writing each field at the resolution its
  sensor can actually resolve is worth more than the compressor is.
- **Timestamps are the exception, and finding that out is the whole story.**
  Rounding them to 1 ms — twenty times finer than the shortest interval
  between samples, and obviously harmless — moved real scores: fastSmooth
  8800 → 8799, fastAggressive 8116 → 8112. Speed and acceleration are Δx/Δt,
  and at 10 Hz a millisecond is 1% of Δt. A sweep across IMU precision from
  5 to 9 decimal places changed nothing, and coordinates were innocent even
  at twelve; it was the timestamp every time. Rounding them also saved
  **nothing** — 307,638 bytes against 307,661. A real risk to a driver's
  score for 23 bytes in the wrong direction.
- **The wire format moved into the Kit.** It lived in the iOS uploader,
  which put the one format that crosses the language boundary in the half of
  the project Linux cannot test — so the fixture the server was held to was
  hand-written. `sogen telemetry-blob` now emits a real gzipped blob from the
  uploader's own code path, and the Deno suite validates *that*
  (`make regen-telemetry-contract`). Same pattern as the course proposal.
- **SHA-256 written out in Swift**, because the envelope hash is the number
  that binds a drive to its data and `CryptoKit` does not exist on Linux —
  so it could never be tested here. Held to the published NIST vectors, and
  the contract test confirms it agrees with Web Crypto. The hash is over the
  **compressed** bytes, which is the semantic most easily got backwards: the
  server hashes what it fetched, before decompressing.
- **A 90-day retention policy** (migration 0035 + `purge-telemetry`, nightly
  at 03:20 UTC). The envelope stays when the blob goes — it is the record
  that the data existed. **A run that has not been scored is never purged**,
  however old: its blob is the only copy of a drive somebody did. Neither is
  a failed one, which may yet be re-driven.
- The purge marks *only* what Storage confirmed it deleted. Marking an
  unconfirmed row would strand the blob forever — nothing would list it
  again, and it would sit in the bucket, paid for, holding somebody's
  location history. Verified by reintroducing the flaw and watching the test
  go red.
- **The gzip path now meets the real stack**: a compressed blob through real
  Storage into the real scorer, asserted to produce the identical score to
  the same drive uncompressed. Every piece had been tested and the whole
  path had not.

At 100,000 users this is the difference between a negligible storage line
and ~$800/month.

**366 Kit · 360 pgTAP · 114 Deno · 10 e2e · xval · parse · a11y · escaping.**

### 2026-08-16 — Notifications, the offer, and the catalog doubled again
Three gaps that were not defects — they were things the product simply did
not have.

- **Notifications, and the rule that comes before all the others.** Nothing
  existed: no `UNUserNotificationCenter`, no device-token table, no
  entitlement. The first check is not permission and not quiet hours — it is
  **whether the person is currently driving**. A banner on a hairpin is not a
  notification, it is a hazard, and no engagement metric is worth it. The
  test stacks every reason to send (authorised, urgent, midday, nothing sent
  yet) and still expects silence. Then: nothing without permission, a hard
  daily ceiling that *urgent* does not lift, and quiet hours on the driver's
  **local** hour. `DriverNotifications` is Kit-side and Linux-tested; the app
  holds only the adapter. Remote push is deliberately absent — APNs needs the
  Apple Developer account — but the seam is shaped so it slots in without the
  policy moving.
- **The paywall was never offered, only triggered.** Pro appeared reactively:
  a second car, a custom course, the Profile upsell, the out-of-runs gate.
  That misses everyone who never hits a gate. It is now offered **once**, at
  the end of onboarding — placed last deliberately, after safety, sign-in and
  location, because nothing may stand between a driver and their first drive
  — and it says plainly how to skip.
- **803 courses across 51 countries** (was 397/30). Weighted to the revenue
  markets, India kept deep on the ghats. **Geometry is not authored**: every
  course is routed over real OpenStreetMap roads by OSRM, and the manifest
  carries only waypoints, a length hint and an editorial difficulty. A
  waypoint in the wrong valley produces a route outside its hint and is
  rejected into `report.json` — which is what caught twelve of mine, and a
  Brazilian road a sign flip had put in the North Atlantic.
- The Mac caught what Linux cannot: holding a `UNUserNotificationCenter` as a
  stored property makes the type unsendable under strict concurrency. Fetched
  per call instead, rather than silenced with `@preconcurrency`.

**335 Kit · 346 pgTAP · 101 Deno · xval · parse · a11y · escaping.**

### 2026-08-15 — The audit with axes, performance at scale, and a route onto a phone
The rule adopted this pass: **a guard that cannot fail on the bug it was
written for is not a guard.** Every mechanical check was tested by breaking
the thing it protects; two did not go red, and were rewritten.

- **A course name could take over the operator's account.** The most serious
  finding of the project so far, and it was a chain rather than a bug: free
  text at course creation → `validate-course` checking only `typeof
  name !== "string"` → stored → returned by `admin_top_courses` → interpolated
  into `admin.html` with `innerHTML` and no escaping anywhere in the file.
  A course named `<img src=x onerror=…>` ran in the **operator's** session —
  the one account that can read the whole business, holding a live admin
  token in that page. Fixed at the sink (escape by default, opt out
  explicitly) and at the door (length + control/bidi bounds). Markup is
  deliberately *not* stripped at the door: refusing `<` would reject
  "Ampère <-> Curie" and still would not make an unescaped renderer safe.
  `tools/web-escaping-check.sh` is in `make test` and fails when the escaping
  is removed.
- **Money, out of order.** The webhook's upsert was idempotent but not
  order-independent, and Apple guarantees retries, not order. A retried
  renewal arriving after a refund handed Pro back to a refunded customer for
  the rest of the period; and `user_id: appAccountToken ?? null` wrote NULL
  over an attributed subscriber on any notification carrying no transaction
  info — unentitling a paying customer *and* leaving the row claimable by
  someone else. Both guards now live in the database.
- **Read performance at scale.** Measured against 50,000 courses and 20,000
  leaderboard entries. Browse scanned the whole catalog every session (wrong
  index column, and the right index unusable under RLS because PostGIS
  predicates are not `LEAKPROOF`): 127 ms → 11.8 ms. The leaderboard ranked
  the entire product to show fifty rows: 47.8 ms → 1.89 ms. The national and
  friends boards were showing **global** ranks, so the best of five friends
  read `#4,912`.
- **Engine complexity on a long drive.** Every other test drives a
  four-minute course; a real drive lasts an hour. Course tracking was
  O(points × segments) with both growing — 10.07× for 4× the input, now
  linear. Guarded at the **stage** level, because the whole-pipeline test
  passed with the quadratic step reintroduced.
- **Trust boundaries moved for performance.** Making browse fast required
  `SECURITY DEFINER`, which bypasses RLS. The migration claimed the inlined
  predicate was the same expression as the policy; they already disagreed. A
  test now compares the two *answers* across every visibility × status ×
  ownership × friendship combination, re-derived from the live policy.
- **Abuse and cost**: the telemetry bucket had `file_size_limit = NULL`, and
  course creation was gated on Pro **and nothing else** — one $4.99
  subscription could insert unbounded rows into the catalog every driver
  browses. Every user-writable text column is now bounded, with a test
  asserting the unbounded set is empty.
- **"All its data" was still false**, the same way as last time: a cascade
  only reaches what points *at* you. A private course nobody had driven
  outlived the account, still holding the geometry of a road — often the one
  they live on. Courses others have driven stay, anonymised, because those
  runs are their drivers' records. The privacy policy said neither; it does
  now.
- **Observability**, previously an axis with nothing under it: `admin_health`
  surfaces the four failures where the app carries on looking normal — jobs
  that gave up, jobs past their retry time (which means the sweeper is not
  running, and it raises no error), subscriptions attached to no account, and
  finished drives with no verdict. Each with the age of the oldest, because a
  count cannot tell "this morning" from "since March". Still nothing pushes:
  somebody has to open the console.
- **A route onto a real iPhone, without owning a Mac.** TestFlight installs a
  signed build on a real device and does not review internal builds first;
  the archiving that needs macOS now happens on the CI Mac. And usefully
  *today*: the nightly job also builds for a real device, so arm64-against-
  the-device-SDK failures — an entire class sitting between us and the first
  drive — are closed for free.

Recorded in **docs/AUDIT.md**, including what was deliberately *not* changed
and the axes still holding nothing: alerting, rate limiting beyond the daily
course ceiling, and backups.

### 2026-08-14 — A systematic audit, along defined axes
Run after "time and again you find something new — do it once for all". The
difference from previous passes is method: fixed axes, each worked to
exhaustion, rather than following whatever a grep turned up.

- **Course creation was not properly tested.** Unit tests on the builder, a
  geometry contract — and nothing exercising the actual endpoint, its Pro
  gate or its insert. Four e2e cases now, in `make e2e-test`.
- **The ghost port was cross-validated by nothing.** Golden vectors carry
  scores, flags and verdicts, not ghosts — so `ghost.ts` had no coverage at
  all on the competitive moat, and it changed three times in one day.
  `sogen ghost-xval` now holds it to the Swift reference point for point,
  inside `tools/xval.sh`.
- **TRUNCATE was granted to every client role** by a Supabase platform
  default, and TRUNCATE bypasses RLS entirely. Not reachable through
  PostgREST; revoked anyway, with the default privileges changed so new
  tables do not re-acquire it.
- **"All its data have been deleted" was false.** The cascade cannot reach
  the raw GPS blobs — storage tables refuse direct deletes — so they
  survived the account. A `delete-account` edge function now clears them
  first and fails closed.
- **Four screens shared one dead end**: a signed-out state rendered as a
  failure with a "Try again" button that could never work. Fixed once in
  `CourseDetailView` last week and not generalised; now one `SignInPrompt`.
- A quarantined run was silent; `pendingCount()` was dead and wrong.

**317 Kit · 268 pgTAP · 102 Deno · 9 e2e · xval (now with ghosts) · parse ·
a11y.**

### 2026-08-14 — Course creation, and the moat
The catalog was a fixed asset: 397 curated courses and no way to add one.
`validate-course` had existed and been tested since L8 with nothing able to
reach it — the largest built-but-unreachable feature in the project.

**You make a course by driving it.** The only route, deliberately: nobody
publishes a road they have never been down, the geometry is real rather than
sketched, and an unsafe or impossible course cannot be made by someone who
has not tried it.

- `CourseBuilder` (Kit, Linux-tested): Douglas–Peucker simplification,
  re-splitting of long segments, five gates snapped to real vertices, turn
  counting that feeds the derived benchmark.
- The app proposes, the server decides — clients stay read-only on the
  catalog and `validate-course` re-runs every rule.
- **The contract is tested across both languages.** `sogen course-proposal`
  emits what the app actually sends and the Deno suite validates that, not a
  hand-written fixture. If the halves disagree, a driver is told a road they
  just drove is invalid.
- Validator failures are shown in a driver's words, all at once.

Caught while wiring it: `createCourse` decoded `id` from a response that
returns `courseId` — visible only against a real server.

**317 Kit · 253 pgTAP · 81 Deno · e2e · xval · parse · a11y.**

### 2026-08-14 — Re-auditing the day's own fixes
The recurring lesson here is that **fixes need their own adversarial pass**.
Swept everything written this week; found nine defects, five of them in code
written hours earlier.

- **Crash recovery was dead code.** `InFlightRecorder.recover()` was never
  called by anything. The recorder journalled every drive and orphaned the
  file forever — the feature looked finished and did nothing.
- **Journal writes were unordered.** A `Task` per sample meant thousands of
  independent actor calls racing at 50 Hz, with no ordering guarantee. A
  recovered file could hold a scrambled timeline.
- **The journal was deleted before the run was queued**, reopening the exact
  crash window it exists to close.
- **Staging counted as traffic.** Stopped time was measured across the whole
  recording, so 70 s waiting at the line — which calibration asks for —
  flagged a flawless run as held up. Measured 59.9 s of "traffic" on a run
  with none.
- **Every user-created course scored ZERO pace, permanently.**
  `validate-course` never set a benchmark, `paceScore` returns 0 without one,
  and pace is 35% of the score. Custom courses are a paid feature. Fixed in
  the database with a trigger + backfill + check constraint, so the invalid
  state is now unrepresentable rather than merely fixed at one call site.
- Recovered drives were scored against a hardcoded 300 s benchmark; the
  Explore "New" filter reversed distance order and called the furthest
  courses new; `abort()` orphaned the journal; and a signed-out driver
  arriving from Explore or a shared link hit "Sign in to load this course"
  rendered as an error with a Try again button that could never work.

Also verified, and holding: RLS survives the new browse aggregates (a
private course leaks through neither `courses_near`, `courses_in_region`
nor `course_regions`), every `admin_*` function 401s to anon, and no
trigger has regressed to the `current_user`-in-a-DEFINER bug.

**303 Kit · 242 pgTAP · 76 Deno · xval · parse · a11y.**

### 2026-08-13 — The share card, and the reason nobody saw it
The result screen showed the score one way and hid a completely different
card behind a button. A driver who had never tapped it had no reason to
believe anything was there — the screen above already looked finished —
so most would hit Done and the growth loop never fired.

- **The result screen now IS the card.** One `RunShareCard` definition
  feeds both the on-screen hero and `ImageRenderer`, so the preview and
  the export cannot drift. Sharing is the primary button; leaving is the
  ghost button under it.
- **The card is rebuilt around the road.** The route was a 30%-opacity
  watermark; it is now the hero. A score is a number anyone could type —
  the shape of the road you drove is the one thing on the card nobody
  else has. Elapsed time joins the score on a shared baseline, and the
  four disciplines became a strip instead of four stacked bars.
- **Honesty fix:** the verdict badge only rendered when a run was
  VERIFIED, so an unranked run produced a card with no badge — which
  reads as verified to anyone who sees it. It now renders NOT RANKED and
  NOT ELIGIBLE too.
- Two layout defects were caught only by CI screenshots (route through
  the digits, dead space above the footer) — the same class as the "100"
  that wrapped to two lines. Without a Mac, rendered output is the only
  place these are visible; the demo tour now also photographs the garage
  and the flying-start verdict, which had never been captured at all.

### 2026-08-13 — The garage, and the start line
Two user directives, both of which turned out to be real gaps.

- **Multiple cars (migration 0017).** There was no vehicle concept anywhere
  — the "vehicle" hits in the codebase were all vehicle-FRAME orientation
  math. The free tier now includes one car, Pro adds a garage, and the
  vehicle is recorded on the RUN so selling a car never deletes the drives
  you did in it. Enforced by database triggers, not just the app, and a run
  cannot claim a car belonging to someone else. 11 pgTAP tests.
- **The flying start.** Entry speed at the start gate was completely
  unbounded, so arriving at 100 km/h with a run-up was free pace against a
  driver launching from the line — on a score that is 35% pace. Now flagged
  `flyingStart` at warning severity: scored, shown, never ranked. Landed in
  the Swift reference AND the TypeScript port in one commit because golden
  vectors compare integrity flags; xval still reproduces all 12 byte-exactly
  (the check is inert on them — the simulator integrates from rest, which
  is the standing start the rule now asks of everyone).
- The rule is stated on the READY screen BEFORE the clock exists and
  explained on the result screen after. DriveRunOutcome now carries
  integrityFlags so the UI can say WHY a run wasn't ranked.
- **docs/FAIRNESS.md** catalogues the whole family: what is handled, and the
  seven cases that are not — led by traffic/stopped time, which on urban
  courses dwarfs everything else here.

### 2026-08-13 — Third audit: payments, permissions, logins
A dedicated review of the three areas the user named. Both definitive
questions came back badly, and both are fixed:

- **Money could never have reached the server.** The App Store webhook wrote
  five columns; `user_id` and `latest_transaction_id` are NOT NULL and were
  not among them, so every notification 500'd. Nothing linked an Apple
  transaction to a user at all. Now: `appAccountToken` carries the user id,
  migration 0015 allows unattributed rows plus a `claim_subscription` RPC
  that can only take unowned rows, `has_active_pro` requires production +
  a real expiry (sandbox granted production Pro; a null expiry granted
  PERMANENT Pro), and Apple's TEST notification returns 200 so the URL can
  be verified.
- **The free tier was not enforceable** — UserDefaults only, reset by
  reinstall or a clock change, checked nowhere on the server. `score-run`
  now enforces it on a server-derived UTC day.
- **Nobody could sign in**: `[auth.external.apple]` was `enabled = false`.
  Apple enabled, Google configured, callback allow-listed.
- Auth lifecycle: transient refresh failures no longer sign users out,
  refresh is single-flight (concurrent 401s double-spent the token, which
  rotation can treat as reuse and revoke the family), account deletion
  clears session state, sign-out clears entitlement/run-count/queue badge.
- **A queued run could upload to the wrong account** — one device, two
  drivers. PendingRun now records its owner; the queue skips (never
  deletes) other accounts' runs.
- **The no-GPS watchdog I added yesterday was dead code** and the checklist
  claimed "GPS locked" with zero fixes — the trapped-drive-screen bug
  reintroduced through a different door. Fixed properly this time.
- Built alongside: ghost pin on the drive map (needed a new engine inverse,
  `progress(atElapsed:)`), Google sign-in with no SDK added, and a
  rebuilt share card that no longer posts a raw UUID.
- Added `PrivacyInfo.xcprivacy` (submission blocker since May 2024).

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
