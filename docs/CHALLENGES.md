# Today's Challenge — dynamic daily assignment

> Living document (directive 2026-08-13). How the daily challenge finds a
> course for every user without hand-authoring one per city.

## Principle

```
USER LOCATION → LOCAL DATE → ELIGIBLE COURSES NEARBY → RANK → SELECT
             → ASSIGN AS TODAY'S CHALLENGE (cached per user/day)
```

One **global format** per day (SMOOTH_SPRINT for now); every user gets a
**local course** for it. Users in LA, London and Amsterdam drive different
roads but the same challenge format. There is no "city" unit anywhere —
selection is a pure radius search from wherever the user actually is.

## Pieces

| Piece | Where | Role |
|---|---|---|
| `challenge_assignments` | migration 0013 | Per-(user, local_date) row: cache + rotation history + debug trail. Service-role writes only; owner-only reads. Rows exist only for users who opened the app that day. |
| `challenge_candidates()` | migration 0013 | One PostGIS round-trip: eligible courses within a radius + every ranking signal (proximity, verified drivers, days since driven/assigned, best friend entry, participants today, your best). Visibility mirrors courses RLS (public+active / own / friends via `are_friends`). |
| `course_route()` | migration 0013 | Drive-ready GeoJSON polyline + gates, same visibility rules. No WKB on clients. |
| `_shared/challenge/` | edge fns | `formats.ts` (registry), `localdate.ts` (IANA tz → longitude fallback → UTC), `ranking.ts` (pure, deterministic, weights configurable). |
| `today-challenge` | edge fn | The GET-shaped flow below. `{debug: true}` returns ladder, candidate scores and selection reason. |
| Home screen | `HomeView.swift` | Renders the assignment: format, distance, ~duration, real participants, your/friend best, first-record state, graceful empties. |

## Selection flow

1. Client POSTs `{latitude?, longitude?, timezone?}` (timezone = IANA id).
2. Local date resolves from tz (longitude/15° if missing; UTC last).
3. Cached assignment for (user, local date)? → rebuild live extras, return.
4. Radius ladder **10 → 25 → 50 → 100 km** (`CHALLENGE_RADII` env): stop as
   soon as ≥3 candidates, or any candidate at ≥25 km — never send someone
   100 km away past a good nearby course.
5. Rank candidates (weights via `CHALLENGE_WEIGHTS` env):
   proximity 0.28 · quality 0.22 · freshness 0.24 · friend activity 0.12 ·
   participation 0.06 · format fit 0.08 · seeded rotation jitter 0.04.
   Freshness decays on *driven* AND *shown*; recovery in a week. Seed is
   `userId:localDate` — stable within a day, rotates across days.
6. Winner upserted into `challenge_assignments` with the full ranking
   snapshot in `reason`; response includes course meta + polyline + gates.

## Honesty rules (non-negotiable)

- Participants today = real distinct drivers since local midnight. Zero
  stays zero; the card hides the chip instead of inventing numbers.
- Nobody on the course yet → `firstRecord: true` → "Set the benchmark".
- No courses within 100 km → `state: "coming-soon"` ("Today's Challenge is
  coming to your area"). No location → `state: "unavailable"` with an ask.
  Neither fabricates anything.
- Friend bests come only from `leaderboard_entries` through `are_friends`.
- Private courses never leave their owner; friends-only only via friendship.

## Scoring

Unchanged. The challenge feeds the selected course into the existing
DriveSession → score-run pipeline. Scores are already course-relative
(pace vs the course benchmark, spec §46) so cross-course comparison within
a format is inherently normalized — no second scoring system exists.

## Extending

- **New format**: add a registry entry in `formats.ts` (optionally set
  `CHALLENGE_FORMAT` per day). Ranking picks up `preferredDistanceMeters`
  automatically.
- **Course generation**: when inventory is insufficient, a future
  CourseGenerationEngine can slot in at the "coming-soon" branch — the
  seeding pipeline in `tools/seed-courses/` is the natural core.
- **Debug**: `POST functions/v1/today-challenge {"debug": true}` or read
  the user's `challenge_assignments.reason` (ladder, per-candidate scores,
  why-selected, friend snapshot).

## Testing

- pgTAP `0012_today_challenge_test.sql` (16): grants/RLS, visibility rules,
  radius behavior, route payload.
- `today_challenge_unit_test.ts` (16): local dates across timezones,
  rotation, friend boost, nearest-isn't-best, honesty, config parsing.
- `today_challenge_integration_test.ts` (9 scenarios, live stack, per-run
  isolated geography): ladder expansion, caching, rotation, friend pull,
  single-course areas, empty areas, no-location, local-date isolation.
