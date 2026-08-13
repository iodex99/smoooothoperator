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

Broad, revenue-weighted coverage (directive 2026-08-13): the catalog leads
with the monetization markets (spec §10 — US, UK, DE, CA, AU, NZ, CH,
Nordics, NL, IE, UAE) while keeping India genuinely deep, and only ships
courses drivers recognize. Current shape: 250 courses across 30 countries
(US 53, IN 30, GB 20, AU 17, IT 13, CH/DE/FR 11 each, CA 10, …).
Growth is a manifest edit — pipeline, validation, and benchmarking are
automatic; the pgTAP catalog suite enforces size floors, market depth, and
integrity on every regeneration.

## Known-unroutable famous roads (drop list)

OSM access/width/toll tagging makes the routing engine refuse these despite
being legendary drives; revisit with a custom routing profile later:
Conor Pass (IE, width limits), Kalhatti Ghat (IN, forest checkpoint tags),
Silvretta Hochalpenstraße (AT, toll/private tagging).
