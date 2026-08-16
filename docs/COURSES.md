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

## Where the road list comes from (and where it does not)

The manifest is editorial: somebody has to decide that Glendora Mountain Road
belongs in the catalog and a dual carriageway does not. That decision is made
from driving-community knowledge — the roads named unprompted in car forums,
regional scenes and enthusiast press.

**It is NOT scraped from Reddit, and the 2026-08-15 expansion should not be
described as if it were.** Reddit blocks this project's user agent outright:

    WebSearch(allowed_domains=["reddit.com"])
    -> 400: the following domains are not accessible to our user agent

Search engines surface Reddit threads only as thin second-hand summaries. So
the expansion used general enthusiast sources where they were reachable, and
domain knowledge otherwise. That is a weaker input than reading the threads
would have been, and it is written down here rather than glossed.

What is NOT editorial, and cannot be: the geometry. Every course is routed
over real OpenStreetMap roads by OSRM. A waypoint dropped in the wrong valley
produces a route outside its declared `expectedKm` window and is rejected into
`report.json`. That is the check which makes a hand-authored coordinate safe.

## Catalog philosophy

Broad, revenue-weighted coverage (directive 2026-08-13): the catalog leads
with the monetization markets (spec §10 — US, UK, DE, CA, AU, NZ, CH,
Nordics, NL, IE, UAE) while keeping India genuinely deep, and only ships
courses drivers recognize. Current shape: 803 courses across 51 countries (US 223, GB 88, IN 55, AU 46,
DE 38, CH 31, CA 30, FR 30, JP 29, IT 27, NO 22, NZ 21, ES 20, IE 17, …) —
the 2026-08-15 doubling directive, applied across every §10 market and
widening coverage from 30 countries to 51.
— the 2026-08-13 doubling directive applied to every §10 market.
Growth is a manifest edit — pipeline, validation, and benchmarking are
automatic; the pgTAP catalog suite enforces size floors, market depth, and
integrity on every regeneration.

## Known-unroutable famous roads (drop list)

OSM access/width/toll tagging makes the routing engine refuse these despite
being legendary drives; revisit with a custom routing profile later:
Conor Pass (IE, width limits), Kalhatti Ghat (IN, forest checkpoint tags),
Silvretta Hochalpenstraße (AT, toll/private tagging), Lions Road (AU),
Gentle Annie (NZ), San Marcos Pass CA-154 (US), Unaweep Canyon CO-141 (US)
— persistent wrong-way routings or >80 km after routing.
