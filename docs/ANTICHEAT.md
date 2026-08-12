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

## Test coverage

Every cheat simulator profile (mockGPS, impossiblePhysics,
timestampManipulation) must produce `invalid`; every degraded-signal profile
(drift, jump, missing GPS, sensor disagreement) must produce
`questionable`/`verified` per its severity — and clean profiles must never be
flagged (false-positive property tests). See TESTING.md.
