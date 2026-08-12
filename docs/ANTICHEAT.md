# Anti-Cheat & Run Verification

> Living document. Detection details intentionally stay coarse here; exact
> thresholds live in code + config.

## Verdicts (spec §44)

Every run gets confidence scores (GPS, sensor, route, integrity) and an overall
verdict:

- **verified** — eligible for leaderboards.
- **questionable** — user sees their result; ranks nowhere; nobody is accused.
- **invalid** — clear violation (cheat or unusable data); excluded.

Only `verified` runs enter competitive leaderboards (enforced server-side).

## Signals (`IntegrityFlag`, spec §45)

mock location, GPS replay, impossible speed, impossible acceleration,
timestamp anomalies, route skipping, GPS jumps, sensor/GPS disagreement,
suspicious gaps, device integrity anomalies.

Thresholds are contextual (hard braking at 60 mph ≠ at 10 mph) and configurable.

## Trust model

1. **The server is authoritative.** The client's score is provisional. The
   `score-run` edge function re-runs integrity checks and scoring on the
   uploaded raw telemetry; `leaderboard_entries` is writable only by the
   service role. A client cannot submit `score = 99999`.
2. **Deterministic checks are ported to TypeScript** and covered by
   cheat-profile golden vectors (each carries an expected verdict).
3. **Client-only signals** (iOS mock-location flag, device checks) are
   submitted as attestation fields — evaluated as evidence, never trusted.
   App Attest/DeviceCheck integration is a planned hardening step (post-MVP).
4. **Uncertainty never accuses.** Weak data → `questionable`, not `invalid`.

## v1 detector notes (L3, implemented)

- **Streak gating**: impossible *implied* speed/acceleration must persist
  across consecutive pairs — isolated violations are honest multipath jumps
  (already rejected by the trajectory gate; surfaced as warnings via the
  rejection-rate check).
- **Mock location** needs ≥2 combined signatures (zero accuracy variance,
  metronome fix clock, dead IMU while moving) — one alone is a warning.
- **Gyro ↔ GPS heading consistency** (p95 ratio over ~1 s heading spans)
  catches scaled/injected IMU without false-flagging aggressive driving.
- **Clock manipulation**: raw timestamp regressions, plus the median
  implied/reported speed ratio leaving 0.7–1.3.
- **Route**: missed gates or corridor deviation (judged against the whole
  course, progress window-gated) → critical.
- **Known v1 limitation:** slow correlated GPS drift (position bias with an
  honest accuracy field) is not detectable without map context; such runs
  verify. A map/road-context check is future hardening. Pinned by test.

## Test coverage

Every cheat simulator profile (mockGPS, impossiblePhysics,
timestampManipulation) must produce `invalid`; every degraded-signal profile
(drift, jump, missing GPS, sensor disagreement) must produce
`questionable`/`verified` per its severity — and clean profiles must never be
flagged (false-positive property tests). See TESTING.md.
