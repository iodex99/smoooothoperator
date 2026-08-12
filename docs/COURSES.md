# Platform Course Catalog

> Living document. The catalog is data, not code: edit the manifest,
> regenerate, review the diff.

## How platform courses are made (spec §56)

```
tools/seed-courses/manifest/*.json     ← curated famous driving roads
        │  (name, country, category, 2-5 waypoints, expected length, hint)
        ▼
tools/seed-courses/generate.ts
        │  OSRM (OpenStreetMap) → real road geometry
        │  simplify (≤400 m point spacing, Douglas–Peucker 7 m)
        │  checkpoints at 0 / 25 / 50 / 75 / 100 % (radius 40 m)
        │  CourseValidator — the SAME rules the app and validate-course use
        │  turn count + difficulty (curated hint × measured turn density)
        │  sogen benchmark — fastSmooth simulated over the real geometry
        ▼
supabase/seeds/platform_courses.sql    ← generated, committed, reviewed
```

Run: `SmoooothKit build` first (sogen), then
`deno run --allow-read --allow-write --allow-net --allow-run --allow-env=OSRM_URL tools/seed-courses/generate.ts`.
Set `OSRM_URL` to a self-hosted OSRM for large regenerations — the public
demo server is rate-limited (the script throttles to ~1 req/s).

## Editorial rules

- **Real, public, legal roads only.** Famous passes, ghats, canyon runs,
  coastal flows, forest B-roads; flowing urban parkways sparingly. Dense
  stop-light grids make unsafe, noisy courses — avoid.
- Length sweet spot 5–45 km; long touring routes are split into named segments.
- Hill courses run the classic direction (usually the climb).
- Course IDs are deterministic (UUID from slug): regeneration updates
  nothing silently and never duplicates.
- Rejected entries land in `tools/seed-courses/report.json` with reasons
  (wrong-valley routing shows up as a length-window failure).

## Benchmarks are reference benchmarks (spec §57)

`benchmark_seconds` = a strong smooth driver **simulated** over the actual
geometry (fastSmooth profile, fixed seed), tightened 3%. It is displayed as
"Course benchmark" — never as a human record. Real verified user records
replace it in prominence as leaderboards fill.

## Attribution & licensing

Road geometry is derived from **OpenStreetMap** data (© OpenStreetMap
contributors, ODbL) routed via OSRM. The app's About screen must credit
OpenStreetMap. Course names/descriptions are our own editorial content.

## Catalog philosophy

Quality and leaderboard density over blanket coverage: a few hundred
courses drivers recognize and rave about beat thousands of dead ones.
Scaling to more regions is a manifest edit — the pipeline, validation,
and benchmarking are already automatic.
