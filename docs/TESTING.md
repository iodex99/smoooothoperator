# Testing Strategy

> Living document. The bar is "enterprise grade": every engine behavior, edge
> case, and security boundary has an automated test that runs on Linux.

## What runs where

| Suite | Command | Framework | Covers |
|---|---|---|---|
| Kit unit/property/golden | `make kit-test` | swift-testing | All engines, models, state machines |
| DB schema + RLS | `make db-test` | pgTAP via `supabase test db` | Every table, every policy, every trigger |
| Edge functions | `make edge-test` | `deno test` | TS scoring/integrity ports, contracts |
| End-to-end | `make e2e-test` | `deno test` + live stack | Upload → score → rank → ghost, course creation, account deletion, against real Postgres/Storage |
| Cross-validation | `make xval` | script | Swift scorer ≡ TS scorer on all golden vectors |
| iOS parse gate | `make syntax-check` | `swiftc -parse` | Blind-authored iOS layer parses |
| Kit purity | `make lint` | grep | No Apple-only imports in SmoooothKit |

**Not testable on Linux (deferred to Mac sessions, tracked in IOS-NOTES.md):**
SwiftUI rendering, real CoreLocation/CoreMotion behavior, StoreKit purchases,
background-location behavior, real-drive telemetry.

## Test kinds

1. **Unit tests** — exact behavior of small pieces (state machines, math).
2. **Property-based tests** — in-house seeded `Gen<T>` (Tests/Support, lands L1).
   Key properties: scoring monotonicity (worse driving never scores higher),
   score bounds, trajectory idempotence, orientation-estimator convergence
   under randomized phone mounts. Failures print the seed — always reproducible.
3. **Golden-file regression** — `sogen` renders each simulator profile to
   `fixtures/golden/<profile>_<seed>.telemetry.json` + `.expected.json`
   (events, sub-scores, final score, verdict). Engines must reproduce expected
   outputs exactly (quantized values). Regeneration is deliberate:
   `make regen-goldens`, then review the diff like code.
4. **RLS matrix (pgTAP)** — for each table: anon / authenticated stranger /
   friend / owner / service role × select / insert / update / delete.
   Raw telemetry: owner + service role only, always.
5. **Contract tests** — zod schemas in `_shared/schemas.ts` must accept
   Swift-encoded DTO fixtures (`fixtures/contracts/`), and Swift must decode
   zod-authored samples. A DTO drift breaks CI on whichever side forgot.
6. **Cross-validation** — the reason users can trust the leaderboard: the
   score the server computes is provably the score the client previewed.

## The simulator is the test-fixture generator

Every synthetic profile (spec §58) is simultaneously: a dev-mode data source,
a permanent regression fixture, an anti-cheat validation case, and a
cross-language contract vector. Adding an edge case = adding a profile =
gaining a permanent test everywhere. Expectations for the synthetic
competition (spec §59): Fast+Smooth ≫ Fast+Aggressive; Slow+Smooth must NOT
win; cheat profiles → `invalid` verdict, never on a leaderboard.

## CI (GitHub Actions)

- `kit`, `db`, `e2e`, `edge`, `xval`, `lint` — ubuntu, every push/PR. All must pass.
- `ios-build` — macOS runner, manual/nightly only (10× minute cost). Red is a
  "fix on next Mac session" queue item, never a merge blocker.

### A suite that skips itself is not a passing suite

Every e2e test carries `ignore: !stackUp`, so a machine with no Docker sees
skips rather than nine failures about a stack it never started. The cost of
that convenience is a result which looks identical to success:

```
ok | 0 passed | 0 failed | 10 ignored
```

This was the real state of things until 2026-08-18. The e2e suite was in no
CI job at all, and run by hand it silently skipped, because the
`supabase start -x ...` line in the runbook leaves PostgREST stopped.
Scoring, course creation, account deletion and telemetry upload were all
covered on paper by tests that had not run in some time.

`tools/e2e-preflight.sh` now gates `make e2e-test`: it probes PostgREST,
Storage and Auth, and refuses to run the suite — naming the missing service
and the command to start it — rather than let it pass vacuously. The e2e job
in CI runs the same target, so the preflight guards the runner too.

The preflight's own first version had this exact disease: `curl` prints
`000` on a connection failure *and* exits non-zero, so `|| echo 000` produced
`"000\n000"`, which is not `000` and is not a number, and `[ ... -ge 500 ]`
on it fails as a syntax error — which inside an `if` reads as false. It
reported a dead PostgREST as healthy. It was caught by stopping the
container and watching the check pass, which is the only way this class of
bug is ever caught.
