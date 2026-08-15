# How the data moves, and how fast

Every number here was measured on this machine against the local stack, not
estimated. Where a number is bad, the fix is named. Where a number is fine,
it says so — "fine" is a finding too, and the point of writing them down is
that the next person does not have to re-derive them.

The measurements at scale were taken against **50,000 courses** and, for
ghosts, **5,000 ghosts on a single course**. The catalog ships with 397. The
whole point is that 397 hides everything.

---

## Where each thing lives

| Data | Stored as | Why |
|---|---|---|
| Course geometry | `courses.geometry` — PostGIS `geography(LineString)` | Spatial predicates need real geography, not lat/lon floats |
| Course start/finish | `start_point` / `finish_point` geography points | Browse filters on `start_point`; it needs its own index |
| Checkpoints/gates | `course_checkpoints` rows | Ordered, individually addressable, RLS-inherited |
| A run's result | `runs` row + downsampled ~1 Hz polyline | Enough to draw the map, small enough to list |
| **Raw telemetry** | **Blob in the `telemetry` bucket + a pointer row** | A 20-minute drive is ~72,000 samples. As rows that is ~20 MB per run — dead on arrival. Gzipped NDJSON is ~1.5–3 MB |
| Telemetry pointer | `telemetry` row: `storage_path`, `gps_count`, `imu_count`, `byte_size`, `sha256` | The hash is what makes re-scoring honest — the server checks the blob it scores is the blob that was uploaded |
| Ghost | `ghosts.trajectory` JSONB — normalized progress+time | Never raw GPS. A 200-point ghost is **~9.3 KB** of JSON |
| Subscription | `subscriptions` row, written only by the App Store webhook | The client never writes its own entitlement |

The split matters: **nothing large is ever on a read path**. Opening a course
reads rows and one small JSONB blob. The multi-megabyte telemetry is written
once, read only by the scorer, and never touched by the app again.

---

## Browsing — the hottest path in the app

Explore opens on this, every session. It was **O(catalog size)**.

| Query | Before | After |
|---|---|---|
| `courses_near`, HTTP round trip | **127 ms** | **11.8 ms** |
| `courses_near`, database time | 150 ms | ~1 ms |
| `courses_in_region`, database time | 40 ms | **0.136 ms** |

Three separate causes, all invisible at 397 courses:

**1. The spatial index was on the wrong column.** The GiST index covered
`geometry`, the LineString. `courses_near` filters on `start_point`, which
had no index at all. Every Explore open computed a geography distance for
every course in the world.

**2. The index was unusable anyway, because of RLS.** This is the subtle one,
and it is worth understanding because it will recur:

```
courses_near, RLS off  →   33 ms, Index Scan
courses_near, RLS on   →  157 ms, SEQ SCAN, "Rows Removed by Filter: 50404"
```

Row-level security makes a table a *security barrier*. A caller's predicate
may only be pushed below the policy check if the function is `LEAKPROOF` —
otherwise it could reveal a hidden row's contents through, say, an error
message. No PostGIS predicate is leakproof:

```sql
select proname, proleakproof from pg_proc where proname = 'st_dwithin';
--  st_dwithin | f
```

So `st_dwithin` could never become an index condition. Adding the index in
step 1 was necessary and, on its own, completely useless.

The fix is to run the browse functions `SECURITY DEFINER` and apply the
visibility rules *inside*, where they are ordinary predicates rather than a
barrier. **This is the pattern that leaked data once already in this
project**, so the shape is deliberate: the functions take no user id, they
read `auth.uid()` themselves, and the predicate is the RLS policy's own
expression copied verbatim so the two cannot drift apart. `0023_browse_
performance_test.sql` asserts someone else's private course is still
invisible through both of them.

**3. The driver count was a correlated subquery,** so `order by driver_count`
forced a count over `leaderboard_entries` for every matching course before
the sort could start — `limit 50` saved nothing, the work was already done.
Now denormalised onto `courses.driver_count` and maintained by trigger on
every leaderboard write. The count is shown to drivers as "how many people
have driven this", so a count that drifts is worse than a slow one; the
trigger covers insert, delete, and course reassignment, and pgTAP asserts it
follows in both directions.

The region index needed `name` in it — the ORDER BY tie-break. Without it the
scan read all 50,000 matching rows to sort within equal driver counts, which
on a young catalog is *all of them*, because nothing has been driven yet.

### What "nearby" means

`courses_near(lat, lon, radius_meters, max_results)`:

- default radius **50 km**, clamped to **[100 m, 200 km]**
- default 50 results, clamped to **[1, 100]**
- measured from the course's **start point**, not its centroid — you drive to
  a start line, not to an average
- ordered nearest-first

Both clamps are tested, including an absurd radius and the middle of the
Atlantic (which returns nothing, rather than everything).

---

## Opening a course

Measured individually: course row **10.1 ms**, `course_route` **1.2 ms**,
leaderboard **4.8 ms**, personal bests ~2 ms.

The screen was making **four sequential round trips** — the course row, then
`my_vehicle_bests`, then the route, then the best ghost — each waiting on the
last for no reason. Only the ghost genuinely depends on anything. The other
three are now concurrent (`async let`), so the wait is the slowest one rather
than the sum.

---

## The leaderboard

This was the worst thing found, and it came with a correctness bug attached.

`course_leaderboards` computes rank with a window function. A window function
runs *before* ORDER BY and LIMIT, so asking for the top 50 sorts the whole
partition and discards the rest.

| Query | Before | After |
|---|---|---|
| Top 50 of a 20,000-entry board | **47.8 ms** | **1.89 ms** |
| Profile's rank summary | **24.2 ms** | **0.687 ms** |

The profile one was the real problem. It asked with no course filter at all:

```
course_leaderboards?user_id=eq.<id>&select=rank
```

With nothing to partition-prune, the window ran over every entry on every
course, hash-joined every profile, sorted the lot, then threw away all but
the caller's rows — `Rows Removed by Filter: 19999`, to return one row. That
is **O(total entries in the entire product)**, on the profile screen. 24 ms
at 20,000 rows is survivable; the shape is not, and it only goes one way.

It also downloaded every rank the driver held to count the 1s and the ≤10s in
Swift, when it wanted two integers. `my_rank_summary()` counts them where the
rows are.

Three fixes:

1. **Slice, then rank.** `leaderboard_page()` takes the page with ORDER BY +
   LIMIT before any window function exists, then numbers that slice and adds
   the offset. With the tie-break in the index the scan stops after N rows.
2. **The index needed the full sort key.** It stopped at `(course_id, score
   desc)`, so the planner still sorted within equal scores.
3. **There was no index on `user_id` alone.** The unique index starts with
   `course_id`, which cannot answer "which boards am I on" — so every profile
   question scanned the whole table for a handful of rows. This was the
   O(product) term that survived fixing the window function.

The profile also made **three sequential requests** for five numbers, two of
them downloading rows only to call `.count` on the array. `my_rank_summary()`
returns all five in one round trip, counted where the rows are.

### The ranks were also wrong

The national and friends boards filtered the view by country / user id
*after* the global rank was computed. A friends board with five people on it
read:

```
#4,912   #8,201   #15,043
```

Correctly ordered, meaninglessly numbered — and on a friends board the number
is the entire point of the screen. `leaderboard_page()` ranks within the
scope requested, so a friends board reads #1–#5 and a national board has a
#1. pgTAP asserts this for both scopes.

The view is kept: it is the honest definition of a rank, pgTAP reads it, and
it is fine for small sets. It is just no longer what the app calls.

---

## Loading a ghost

`ghosts?course_id=eq.X&order=score.desc&limit=1`, backed by
`ghosts_course_score_idx (course_id, score desc)`.

This one is **fine**, and it is worth recording why, because it looks like it
should have the same RLS problem as browse. It does not: `uuid_eq` *is*
leakproof, so `course_id = X` pushes below the barrier and the index is used.

Worst case measured — 5,000 ghosts on one course, every one hidden except the
single lowest-scoring one, so the scan has to walk the entire index before it
finds a visible row:

```
Index Scan using ghosts_course_score_idx   rows=1
  Rows Removed by Filter: 4999
Execution Time: 10.114 ms
```

10 ms for a deliberately pathological case that will not occur. In the normal
case the top ghost is visible and the scan stops on the first row. No change
made.

---

## Does the payment go through?

The chain, and what proves each link:

| Link | Proven by |
|---|---|
| Apple → webhook | `appstore-notifications` verifies the JWS chain against Apple's root CA and **returns 503 rather than trusting an unverifiable payload**. 10 Deno tests cover the refusals |
| Webhook → subscription row | Status mapping tested per notification type; the row is written service-role only |
| Purchase → the right account | `appAccountToken` attribution, tested in `0013_subscription_attribution_test.sql` |
| Subscription row → entitlement | `has_active_pro`, tested in `0011` and `0020` |
| Entitlement → Pro features unlock | `0020_entitlement_garage_test.sql`, and course creation is re-checked server-side in `validate-course` |

**The honest gap:** the success path cannot be tested end to end here, because
forging Apple's signature is the thing the webhook exists to prevent. Every
link on either side of that signature is tested; the signature itself is
proven only by Apple's own **Test** notification button in App Store Connect
(step 12 of `LAUNCH.md`, which returns 200 specifically so that button works).

Also from `LAUNCH.md` and worth repeating here: without the
`APPLE_ROOT_CA_SHA256` secret the webhook returns 503 **on purpose**, which
means subscriptions silently never activate. That is correct behaviour and a
launch blocker.

---

## Scoring a long drive — the only quadratic step in the engine

Every other test in the Kit drives a course of about four minutes. A driver
will not. At 10 Hz GPS plus 50 Hz IMU, an hour is 36,000 GPS samples and
180,000 IMU samples, and the catalog already ships courses up to **79 km and
661 polyline points**.

Timing each pipeline stage at 4× the input showed seven stages growing 2–4×
and one growing **10.07×**:

```
                     40 seg    160 seg   growth
  orientation         0.6 ms     2.1 ms    3.21x
  trajectory          0.4 ms     0.7 ms    1.94x
  events              1.3 ms     5.1 ms    4.02x
  integrity           1.7 ms     6.0 ms    3.46x
  course tracking     0.9 ms     9.1 ms   10.07x   <--
```

`CourseProgressTracker` took two matches per GPS fix, and **both scanned the
entire course polyline**:

- the *global* match, by design — "am I on the course at all?" has to be
  asked of the whole course, because a deviated path can wander near a later
  bend and must still read as off-course;
- the *windowed* match, by accident — it scanned all segments just to find
  where its few-hundred-metre window started, so the match that exists to
  avoid a full scan performed one anyway.

Both are fixed without changing a single output:

1. **The window bounds are found by binary search.** `startDistance` is
   cumulative, so the segments in the window are a contiguous run.
2. **The global match is skipped on the common path.** It is the minimum over
   *all* segments and the windowed match is a minimum over a *subset*, so
   `windowed ≤ corridor` implies `global ≤ corridor`. A driver on their local
   stretch of road — the whole of a clean run — has already answered the
   question. Only a fix that has left its window consults the whole course,
   and there the exact offset is wanted anyway to record how far off it went.

| | Before | After |
|---|---|---|
| tracking, 8,058 points | 9.1 ms | **1.07 ms** |
| tracking, 20,091 points | ~57 ms (extrapolated) | **2.80 ms** |
| growth for 4× the input | 10.07× | **3.96×** |

This runs on the phone the moment a drive ends, with the driver watching —
and the identical TypeScript port runs on the server for every scored run, so
the same change was made in both.

**What proves it is exact:** all 12 golden vectors still reproduce
byte-for-byte across Swift and TypeScript, `routeDeviation_1` among them —
that is the vector that exercises the off-course branch. `PipelineScalingTests`
now asserts the shape rather than a time, so a quadratic step reintroduced
later fails the build instead of waiting to be measured.

---

## Measured and left alone

Recorded so the next person does not re-derive them.

- **`are_friends()`** is called per row inside two RLS policies, and its
  `(a,b) or (b,a)` form cannot use the functional unique index on
  `(least, greatest)`. It does not need to: the planner bitmap-ORs
  `friendships_addressee_idx` twice, because both halves constrain
  `addressee_id`. Sub-millisecond against 40,000 friendships. Rewriting it to
  match the pair index measured no faster.
- **Signup** — `handle_new_user` fires per row: **20.7 ms**.
- **Run history** already pages at 100.
- **The remaining unbounded server functions** (`course_route`,
  `my_course_rank`, `my_rank_summary`, `my_vehicle_bests`) are bounded by
  their subject — one course's polyline, one integer, one row, one garage.
- **`course_leaderboards`** still contains a window function, and that is
  fine: nothing in the app calls it any more.

---

## What is still unmeasured

- **Every number here is local.** No network latency, no Supabase pooler, no
  cellular. Treat them as lower bounds on the database's contribution, not as
  what a driver on a hillside will see.
- **Telemetry upload over a real connection.** The blob is 1.5–3 MB and gets
  uploaded from wherever the drive ended, which is by construction not a
  place with good signal. The upload queue retries and the run survives, but
  the wall-clock has never been measured on a real network.
- **Storage cost at volume.** ~$0.021/GB-month; a heavy user recording daily
  is roughly 1 GB/year. Fine now, worth a retention policy later.
