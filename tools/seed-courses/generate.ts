// Platform course generator (spec §56: platform courses are manually
// seeded — this tool turns a curated manifest of famous driving roads into
// validated, benchmarked course rows).
//
// Pipeline per manifest entry:
//   waypoints → OSRM (OpenStreetMap) road geometry → simplify (≤400 m
//   spacing kept) → checkpoints at 0/25/50/75/100% → CourseValidator (the
//   SAME rules the app and validate-course enforce) → turn count +
//   difficulty heuristic → `sogen benchmark` reference time → SQL seed.
//
// Run:  deno run --allow-read --allow-write --allow-net --allow-run tools/seed-courses/generate.ts
// Geometry © OpenStreetMap contributors (ODbL) via OSRM — see docs/COURSES.md.

import {
  DEFAULT_COURSE_VALIDATION_CONFIG,
  validateCourse,
} from "../../supabase/functions/_shared/pipeline/validator.ts";
import type { Checkpoint } from "../../supabase/functions/_shared/pipeline/types.ts";
import {
  bearingDegrees,
  distanceMeters,
  type GeoCoordinate,
} from "../../supabase/functions/_shared/pipeline/geo.ts";

interface ManifestEntry {
  slug: string;
  name: string;
  country: string;
  region?: string;
  city?: string;
  category: string;
  description?: string;
  waypoints: [number, number][]; // [lat, lon]
  expectedKm: [number, number];
  difficultyHint: number;
}

interface GeneratedCourse {
  entry: ManifestEntry;
  polyline: GeoCoordinate[];
  checkpoints: Checkpoint[];
  distanceMeters: number;
  turnCount: number;
  difficulty: number;
  benchmarkSeconds: number;
}

const OSRM_BASE = Deno.env.get("OSRM_URL") ?? "https://router.project-osrm.org";
const SOGEN = "SmoooothKit/.build/debug/sogen";
const CATEGORIES = new Set([
  "alpine",
  "ghat",
  "canyon",
  "coastal",
  "forest",
  "moorland",
  "urban-parkway",
  "highland",
  "straight",
]);

// ── Geometry helpers ────────────────────────────────────────────────────────

/** Douglas–Peucker on a local-meter projection. */
function simplify(points: GeoCoordinate[], epsilonMeters: number): GeoCoordinate[] {
  if (points.length < 3) return points;
  const cosLat = Math.cos((points[0].latitude * Math.PI) / 180);
  const project = (p: GeoCoordinate) => ({
    x: p.longitude * 111195 * cosLat,
    y: p.latitude * 111195,
  });
  const projected = points.map(project);
  const keep = new Array(points.length).fill(false);
  keep[0] = keep[points.length - 1] = true;

  const stack: [number, number][] = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [first, last] = stack.pop()!;
    const a = projected[first];
    const b = projected[last];
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const lengthSq = dx * dx + dy * dy;
    let worst = -1;
    let worstDistance = 0;
    for (let i = first + 1; i < last; i++) {
      const p = projected[i];
      let t = lengthSq > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq : 0;
      t = Math.max(0, Math.min(1, t));
      const ex = p.x - (a.x + t * dx);
      const ey = p.y - (a.y + t * dy);
      const d = Math.sqrt(ex * ex + ey * ey);
      if (d > worstDistance) {
        worstDistance = d;
        worst = i;
      }
    }
    if (worst >= 0 && worstDistance > epsilonMeters) {
      keep[worst] = true;
      stack.push([first, worst], [worst, last]);
    }
  }

  const kept = points.filter((_, i) => keep[i]);
  return enforceSpacing(kept, 350);
}

/** Interpolate extra vertices so no pair sits further apart than maxMeters —
 * OSRM emits kilometer-long segments on straights, and the validator (and
 * course corridor logic) needs dense-enough geometry everywhere. */
function enforceSpacing(points: GeoCoordinate[], maxMeters: number): GeoCoordinate[] {
  const out: GeoCoordinate[] = [points[0]];
  for (let i = 1; i < points.length; i++) {
    const prev = out[out.length - 1];
    const gap = distanceMeters(prev, points[i]);
    if (gap > maxMeters) {
      const steps = Math.ceil(gap / maxMeters);
      for (let k = 1; k < steps; k++) {
        out.push({
          latitude: prev.latitude + (points[i].latitude - prev.latitude) * (k / steps),
          longitude: prev.longitude + (points[i].longitude - prev.longitude) * (k / steps),
        });
      }
    }
    out.push(points[i]);
  }
  return out;
}

function totalDistance(points: GeoCoordinate[]): number {
  let total = 0;
  for (let i = 1; i < points.length; i++) {
    total += distanceMeters(points[i - 1], points[i]);
  }
  return total;
}

function pointAtFraction(points: GeoCoordinate[], fraction: number): GeoCoordinate {
  if (fraction <= 0) return points[0];
  const target = totalDistance(points) * fraction;
  let walked = 0;
  for (let i = 1; i < points.length; i++) {
    const step = distanceMeters(points[i - 1], points[i]);
    if (walked + step >= target) return points[i];
    walked += step;
  }
  return points[points.length - 1];
}

function countTurns(points: GeoCoordinate[]): number {
  let turns = 0;
  let previousBearing: number | null = null;
  for (let i = 1; i < points.length; i++) {
    if (distanceMeters(points[i - 1], points[i]) < 1) continue;
    const b = bearingDegrees(points[i - 1], points[i]);
    if (previousBearing !== null) {
      const delta = Math.abs(((b - previousBearing + 540) % 360) - 180);
      if (delta > 25) turns += 1;
    }
    previousBearing = b;
  }
  return turns;
}

// ── External services ──────────────────────────────────────────────────────

async function osrmRoute(waypoints: [number, number][]): Promise<{
  geometry: GeoCoordinate[];
  distance: number;
}> {
  const coords = waypoints.map(([lat, lon]) => `${lon},${lat}`).join(";");
  const url =
    `${OSRM_BASE}/route/v1/driving/${coords}?overview=full&geometries=geojson&continue_straight=true`;

  // A bare fetch here once hung a full regeneration for over an hour: the
  // public demo server stopped answering mid-run, the request had no
  // deadline, and the process sat on a socket at zero percent CPU with
  // nothing written — no output, no error, no way to tell it apart from slow
  // progress. Anything that talks to a shared server somebody else operates
  // needs a deadline and a retry, and this is the whole of that lesson.
  let lastError = "";
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const response = await fetch(url, {
        headers: { "User-Agent": "smooooth-operator-course-seeder/1.0" },
        signal: AbortSignal.timeout(20_000),
      });
      if (response.status === 429 || response.status >= 500) {
        // Rate limited or the far end is unwell: back off rather than
        // hammering a service that is being given to us free.
        lastError = `OSRM ${response.status}`;
        await response.body?.cancel();
        await new Promise((r) => setTimeout(r, attempt * 4000));
        continue;
      }
      if (!response.ok) {
        throw new Error(`OSRM ${response.status}: ${await response.text()}`);
      }
      const json = await response.json();
      if (json.code !== "Ok" || !json.routes?.length) {
        throw new Error(`OSRM: ${json.code ?? "no route"}`);
      }
      return shapeRoute(json.routes[0]);
    } catch (error) {
      // A timeout or a dropped connection is worth retrying; a genuine
      // routing refusal is not, and rethrows immediately.
      const message = String(error);
      if (!/TimeoutError|timed out|connection|network|aborted/i.test(message)) {
        throw error;
      }
      lastError = message;
      await new Promise((r) => setTimeout(r, attempt * 4000));
    }
  }
  throw new Error(`OSRM unreachable after 4 attempts: ${lastError}`);
}

function shapeRoute(route: {
  geometry: { coordinates: number[][] };
  distance: number;
}): { geometry: GeoCoordinate[]; distance: number } {
  return {
    geometry: route.geometry.coordinates.map((c: number[]) => ({
      latitude: c[1],
      longitude: c[0],
    })),
    distance: route.distance,
  };
}

async function benchmark(polyline: GeoCoordinate[]): Promise<number> {
  const tmp = await Deno.makeTempFile({ suffix: ".json" });
  await Deno.writeTextFile(
    tmp,
    JSON.stringify(polyline.map((p) => [p.latitude, p.longitude])),
  );
  const command = new Deno.Command(SOGEN, {
    args: ["benchmark", "--input", tmp],
    stdout: "piped",
    stderr: "piped",
  });
  const output = await command.output();
  await Deno.remove(tmp);
  if (!output.success) {
    throw new Error(`sogen benchmark failed: ${new TextDecoder().decode(output.stderr)}`);
  }
  return JSON.parse(new TextDecoder().decode(output.stdout)).benchmarkSeconds;
}

// ── SQL emission ────────────────────────────────────────────────────────────

/** Deterministic UUID from the slug — regeneration never duplicates rows. */
async function slugUUID(slug: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`smooooth-course:${slug}`)),
  );
  const hex = Array.from(digest.slice(0, 16))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

function sqlEscape(text: string): string {
  return text.replace(/'/g, "''");
}

async function courseSQL(course: GeneratedCourse): Promise<string> {
  const { entry } = course;
  const id = await slugUUID(entry.slug);
  const lineWKT = course.polyline
    .map((p) => `${p.longitude.toFixed(6)} ${p.latitude.toFixed(6)}`)
    .join(", ");
  const start = course.polyline[0];
  const finish = course.polyline[course.polyline.length - 1];

  const gateValues = course.checkpoints
    .map(
      (gate) =>
        `('${id}', ${gate.sequence}, ` +
        `'SRID=4326;POINT(${gate.center.longitude.toFixed(6)} ${gate.center.latitude.toFixed(6)})'::extensions.geography, ` +
        `${gate.radiusMeters})`,
    )
    .join(",\n    ");

  return `-- ${entry.name} (${entry.country}, ${entry.category})
insert into public.courses
    (id, name, description, creator_id, city, region, country, distance_meters,
     estimated_duration_seconds, difficulty, turn_count, geometry, start_point,
     finish_point, benchmark_seconds, visibility, status)
values
    ('${id}', '${sqlEscape(entry.name)}', '${sqlEscape(entry.description ?? "")}',
     null, ${entry.city ? `'${sqlEscape(entry.city)}'` : "null"},
     ${entry.region ? `'${sqlEscape(entry.region)}'` : "null"}, '${entry.country}',
     ${Math.round(course.distanceMeters)}, ${Math.round(course.benchmarkSeconds * 1.35)},
     ${course.difficulty}, ${course.turnCount},
     'SRID=4326;LINESTRING(${lineWKT})'::extensions.geography,
     'SRID=4326;POINT(${start.longitude.toFixed(6)} ${start.latitude.toFixed(6)})'::extensions.geography,
     'SRID=4326;POINT(${finish.longitude.toFixed(6)} ${finish.latitude.toFixed(6)})'::extensions.geography,
     ${Math.round(course.benchmarkSeconds)}, 'public', 'active')
on conflict (id) do nothing;

insert into public.course_checkpoints (course_id, sequence, center, radius_meters)
values
    ${gateValues}
on conflict do nothing;
`;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function processEntry(entry: ManifestEntry): Promise<GeneratedCourse> {
  if (!CATEGORIES.has(entry.category)) {
    throw new Error(`unknown category '${entry.category}'`);
  }
  if (!/^[A-Z]{2}$/.test(entry.country)) {
    throw new Error(`country must be ISO2, got '${entry.country}'`);
  }

  const routed = await osrmRoute(entry.waypoints);
  const polyline = simplify(routed.geometry, 7);
  const distance = totalDistance(polyline);

  const [minKm, maxKm] = entry.expectedKm;
  if (distance < minKm * 750 || distance > maxKm * 1250) {
    throw new Error(
      `distance ${Math.round(distance / 100) / 10}km outside expected ` +
        `${minKm}-${maxKm}km — waypoints likely routed the wrong way`,
    );
  }

  const checkpoints: Checkpoint[] = [0, 0.25, 0.5, 0.75, 1].map((fraction, sequence) => ({
    sequence,
    center: pointAtFraction(polyline, fraction),
    radiusMeters: 40,
  }));

  const issues = validateCourse(polyline, checkpoints, DEFAULT_COURSE_VALIDATION_CONFIG);
  if (issues.length > 0) {
    throw new Error(`validation: ${issues.map((issue) => issue.kind).join(", ")}`);
  }

  const turnCount = countTurns(polyline);
  const turnsPerKm = turnCount / (distance / 1000);
  const turnScore = Math.max(1, Math.min(5, Math.round(1 + turnsPerKm * 1.2)));
  const difficulty = Math.max(
    1,
    Math.min(5, Math.round((entry.difficultyHint + turnScore) / 2)),
  );

  return {
    entry,
    polyline,
    checkpoints,
    distanceMeters: distance,
    turnCount,
    difficulty,
    benchmarkSeconds: await benchmark(polyline),
  };
}

const manifestDir = "tools/seed-courses/manifest";
const entries: ManifestEntry[] = [];
for await (const file of Deno.readDir(manifestDir)) {
  if (!file.name.endsWith(".json")) continue;
  const batch = JSON.parse(await Deno.readTextFile(`${manifestDir}/${file.name}`));
  entries.push(...batch);
}
entries.sort((a, b) => a.slug.localeCompare(b.slug));

const slugs = new Set<string>();
for (const entry of entries) {
  if (slugs.has(entry.slug)) throw new Error(`duplicate slug ${entry.slug}`);
  slugs.add(entry.slug);
}

console.log(`processing ${entries.length} manifest entries…`);
const accepted: GeneratedCourse[] = [];
const rejected: { slug: string; reason: string }[] = [];

for (const entry of entries) {
  try {
    const course = await processEntry(entry);
    accepted.push(course);
    console.log(
      `  ok ${entry.slug}: ${(course.distanceMeters / 1000).toFixed(1)}km, ` +
        `${course.turnCount} turns, difficulty ${course.difficulty}, ` +
        `benchmark ${Math.round(course.benchmarkSeconds)}s`,
    );
  } catch (error) {
    rejected.push({ slug: entry.slug, reason: String(error) });
    console.error(`  REJECTED ${entry.slug}: ${error}`);
  }
  // Be polite to the public OSRM server.
  await new Promise((resolve) => setTimeout(resolve, 1100));
}

let sql = `-- Platform course catalog — GENERATED by tools/seed-courses/generate.ts.
-- Do not edit by hand; edit the manifest and regenerate.
-- Road geometry © OpenStreetMap contributors (ODbL), routed via OSRM.
-- Benchmarks are simulated REFERENCE BENCHMARKS (spec §57), not human records.

`;
for (const course of accepted) {
  sql += await courseSQL(course);
  sql += "\n";
}
await Deno.mkdir("supabase/seeds", { recursive: true });
await Deno.writeTextFile("supabase/seeds/platform_courses.sql", sql);

await Deno.writeTextFile(
  "tools/seed-courses/report.json",
  JSON.stringify(
    {
      generatedAt: "see git history",
      accepted: accepted.map((course) => ({
        slug: course.entry.slug,
        km: Math.round(course.distanceMeters / 100) / 10,
        turns: course.turnCount,
        difficulty: course.difficulty,
        benchmarkSeconds: Math.round(course.benchmarkSeconds),
      })),
      rejected,
    },
    null,
    2,
  ),
);

console.log(
  `\ndone: ${accepted.length} accepted, ${rejected.length} rejected → supabase/seeds/platform_courses.sql`,
);
if (accepted.length === 0) Deno.exit(1);
