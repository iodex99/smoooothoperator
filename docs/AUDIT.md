# The audit record

Every time this project was asked "is anything else wrong?", something else
was wrong. That is not a run of bad luck — it is what happens when checking
is opportunistic: you grep for what you happen to think of, find something,
fix it, and stop. The next question finds the next thing, forever.

This file exists to end that. It names the axes a product like this can fail
along, records what was checked on each, and — more usefully — records what
was **deliberately not changed** and why. An axis with nothing under it is an
admission, not an omission.

Last full pass: **2026-08-15**.

---

## How to read the verdicts

| | |
|---|---|
| **Fixed** | A real defect. Named, fixed, and pinned by a test that was verified to fail without the fix. |
| **Sound** | Checked and correct. The evidence is recorded so it is not re-derived. |
| **Accepted** | A real limitation, deliberately left. The reasoning is here so it can be revisited, not rediscovered. |
| **Open** | Known, unfixed, and not defensible as "accepted". |

The single most important rule learned this pass:

> **A guard that cannot fail on the bug it was written for is not a guard.**

Every mechanical check below was tested by breaking the thing it protects and
confirming it went red. Two of them did not, first time, and were rewritten.

---

## 1. Read performance at scale

**Fixed.** Measured against 50,000 courses and 20,000 leaderboard entries; the
catalog ships 397, which is exactly why none of it was visible.

- Browse scanned the whole catalog every session — wrong index column, and
  the right index was unusable under RLS because PostGIS predicates are not
  `LEAKPROOF`. 127 ms → 11.8 ms.
- The leaderboard ranked the entire product to show fifty rows, and the
  profile ranked it to return one. 47.8 ms → 1.89 ms; 24.2 ms → 0.687 ms.
- The national and friends boards showed **global** ranks, so the best of five
  friends read `#4,912`.

Full detail and measurements: [PERFORMANCE.md](PERFORMANCE.md).

## 2. Engine complexity on a long drive

**Fixed.** Every other test drives a four-minute course; a real drive can last
an hour. Course tracking was O(points × polyline segments) with both growing —
10.07× for 4× the input. Now linear.

Guarded by `PipelineScalingTests`, which measures the **stage** and not just
the pipeline: the whole-pipeline test passed with the quadratic step
reintroduced, because one quadratic stage among six linear ones does not move
the total enough. That failure is why the stage-level test exists.

## 3. Trust boundaries moved for performance

**Fixed.** Making browse fast required `SECURITY DEFINER`, which bypasses RLS.
The migration claimed the inlined predicate was "the SAME expression as the
RLS policy, so the two cannot drift". They already disagreed.

The difference was in the safe direction, but a comment asserting an
equivalence is not a check. `0026_browse_matches_policy_test.sql` compares the
two **answers** over every visibility × status × ownership × friendship
combination, re-deriving the expectation from the live policy each run.
Verified to fail against a deliberately leaky `courses_near`.

## 4. User-supplied strings and where they are rendered

**Fixed — the most serious finding of the pass.** A driver names a custom
course; the server checked only `typeof name !== "string"`; the operator
console built its tables with `innerHTML` and no escaping existed anywhere in
the file. A course named `<img src=x onerror=...>` ran in the **operator's**
session — the one account that can read the whole business, holding a live
admin token in that page.

Fixed at the sink (escape by default, opt out explicitly) and at the door
(length and control-character bounds). Markup is deliberately **not** stripped
at the door, with a test saying so: rejecting `<` would refuse
"Ampère <-> Curie" and would still not make an unescaped renderer safe.

`tools/web-escaping-check.sh` is in `make test` and verified to fail when the
escaping is removed.

## 5. Money

**Fixed.** The webhook's upsert was idempotent but not order-independent, and
Apple guarantees only retries, not order.

- A retried renewal arriving after a refund handed Pro back to a refunded
  customer for the rest of the period.
- `user_id: appAccountToken ?? null` wrote NULL over an attributed subscriber
  on any notification carrying no transaction info — unentitling a paying
  customer and leaving the row claimable by anyone with the transaction id.

## 6. Data lifecycle and the promises made about it

**Fixed.** "Your account and all its data have been deleted" was false twice,
in the same way both times: a cascade was trusted to mean deletion, and a
cascade only reaches what points **at** you.

- Telemetry blobs survived (fixed earlier, migration 0024).
- Courses survived. `creator_id` is `ON DELETE SET NULL`, so a private course
  nobody had driven became a row invisible to every user forever, still
  holding the geometry of a road the person drove — often the one they live
  on.

Courses nobody has driven now go with the account; courses others have driven
stay, anonymised, because those runs are their drivers' records. The privacy
policy and the in-app confirmation both say so now — they previously said
neither.

## 7. Abuse and cost

**Fixed.** Two unbounded write paths on free-to-create accounts:

- The telemetry bucket had `file_size_limit = NULL`.
- Course creation was gated on Pro **and nothing else** — one $4.99
  subscription could insert unbounded rows into the catalog every driver
  browses.

Also bounded every user-writable text column, guarded by a test asserting the
set of unbounded ones is empty. `profiles.avatar_url` was unbounded, writable
by any account, and read by nothing in the entire product.

## 8. Authorization

**Sound.** Checked behaviourally rather than by reading:

- All 8 `admin_*` functions refuse a non-admin. `admin_mrr_minor` has no
  in-body gate and does not need one — `EXECUTE` is granted to `postgres`
  alone. A heuristic flagged it; the behavioural test cleared it.
- All 6 edge functions authenticate. `validate-course` takes the user id from
  the **token**, never the payload. `appstore-notifications` verifies Apple's
  signature instead, which is correct for a webhook.
- `anon` and `authenticated` cannot `CREATE` in `public` or `extensions`, so
  the `SECURITY DEFINER` functions with a non-empty `search_path` are not
  exploitable. They still deviate from this project's `search_path = ''`
  convention — see Open, below.
- Storage: uploads confined to the caller's own uid prefix, path re-validated
  against the run's owner, reads and deletes owner-only.

## 9. Concurrency

**Sound.** `apply_run_result` takes a row lock on the run, the leaderboard
upsert only improves, and the ghost insert is `on conflict do nothing`, so
double-scoring converges. The `driver_count` trigger was walked through every
mutation path — insert, PB improvement, account deletion, course deletion —
and does not drift.

## 10. Correctness of the engine

**Sound.** 12 golden vectors reproduce byte-for-byte across Swift and
TypeScript, including `routeDeviation_1`, which is what proved the
course-tracking optimisation was exact rather than merely close.

## 11. Error handling on the critical path

**Sound.** The run upload uses `try?`, which looked like a silent failure and
is not: `savedLocally` is derived from the result and both failure branches
tell the driver plainly, including "This phone couldn't save the run — check
your storage."

---

## Accepted

**Today's Challenge can be re-rolled by declaring a different timezone.** The
client sends its IANA zone and the server derives the local date from it, so
shifting zones changes the ranking seed and yields a different course. Bounded
to about three dates at any instant.

Left alone deliberately: nothing is rewarded for completing the challenge — no
streak, no points — and a driver can already browse and drive any course they
like, so the exploit buys a different *suggestion*. A plausibility check
against the driver's longitude would add real failure modes for someone
genuinely travelling, in exchange for nothing. Note the contrast with the free
tier's run allowance, whose day boundary is UTC precisely because money hangs
on it.

**`are_friends()` does not use the pair index.** Its `(a,b) or (b,a)` form
cannot match the functional unique index on `(least, greatest)`. It does not
need to: the planner bitmap-ORs the addressee index twice. Sub-millisecond
against 40,000 friendships, and the pair-index rewrite measured no faster.

**Index creation is not `CONCURRENTLY`.** The migrations take a lock that
would block writes on a populated table. The production database is still
empty — no migration has been pushed — so the first deploy is unaffected. This
becomes real the day a schema change ships to a live database.

---

## Open

**`courses_near`, `courses_in_region` and the `admin_*` functions use
`search_path = public` rather than `''`.** Not exploitable today — no client
role can create objects in those schemas — but it deviates from the
convention every other `SECURITY DEFINER` function here follows, and the
protection is a grant somewhere else rather than the function itself.

**No sensor path has ever seen a real GPS chip.** Every number in this
project comes from simulated telemetry through the real pipeline. This is the
largest unknown in the product and no amount of work in this repository
closes it. It is step 17 of [LAUNCH.md](LAUNCH.md).

**Course creation has never met a real GPS trace either.** The builder is
tested against simulated drives with noise; tunnels, urban canyons and a
phone in a cupholder are not simulated.

**The `slowSmooth` fixture never reaches the finish gate**, so the "slower
driver falls behind" test stays disabled. A fixture limitation, not an engine
defect — but it means the behaviour is unproven.

---

## Axes with nothing under them

Recorded so the gap is visible rather than implied.

- **Observability.** There is no logging, alerting or error reporting story.
  If scoring starts failing in production, nothing tells anyone. The
  `scoring_jobs` table records attempts and failures, so the data exists —
  nothing watches it.
- **Load and rate limiting at the edge.** The daily course ceiling is the only
  rate limit in the product. Nothing bounds request rate per account.
- **Backup and restore.** Delegated entirely to Supabase's managed backups;
  never exercised.
