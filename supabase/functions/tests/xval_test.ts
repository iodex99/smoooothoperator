// Cross-validation acceptance suite (ADR-0002): the TypeScript pipeline port
// must reproduce the committed Swift golden vectors EXACTLY.
//
// For each profile: load fixtures/golden/<p>_1.telemetry.json, run the full
// evaluation pipeline with configs/scoring/v1.json, build a GoldenExpected,
// and deep-compare against fixtures/golden/<p>_1.expected.json.
//
// Run from supabase/functions:
//   deno test --allow-read=../../fixtures,../../configs

import { evaluate } from "../_shared/pipeline/pipeline.ts";
import {
  buildGoldenExpected,
  parseGoldenTelemetry,
} from "../_shared/pipeline/golden.ts";
import { parseScoringConfig } from "../_shared/pipeline/scoring.ts";

// SimulationProfile raw values — one committed golden pair per profile.
const PROFILES = [
  "fastSmooth",
  "fastAggressive",
  "slowSmooth",
  "normal",
  "gpsDrift",
  "gpsJump",
  "missingGPS",
  "sensorDisagreement",
  "routeDeviation",
  "mockGPS",
  "impossiblePhysics",
  "timestampManipulation",
] as const;

/** Repo root is ../../../ from this file — independent of CWD. */
function repoUrl(relativePath: string): URL {
  return new URL(`../../../${relativePath}`, import.meta.url);
}

function readJson(relativePath: string): unknown {
  return JSON.parse(Deno.readTextFileSync(repoUrl(relativePath)));
}

/** Structural deep equality: primitives ===, arrays element-wise, objects by key set. */
function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((item, i) => deepEqual(item, b[i]));
  }
  if (
    typeof a === "object" && a !== null && !Array.isArray(a) &&
    typeof b === "object" && b !== null && !Array.isArray(b)
  ) {
    const aObj = a as Record<string, unknown>;
    const bObj = b as Record<string, unknown>;
    const aKeys = Object.keys(aObj).sort();
    const bKeys = Object.keys(bObj).sort();
    if (!deepEqual(aKeys, bKeys)) return false;
    return aKeys.every((key) => deepEqual(aObj[key], bObj[key]));
  }
  return false;
}

/** Readable diff listing every differing top-level field. */
function describeMismatch(
  actual: Record<string, unknown>,
  expected: Record<string, unknown>,
): string {
  const keys = [...new Set([...Object.keys(actual), ...Object.keys(expected)])]
    .sort();
  const lines: string[] = [];
  for (const key of keys) {
    if (!deepEqual(actual[key], expected[key])) {
      lines.push(
        `  ${key}: actual=${JSON.stringify(actual[key])} expected=${
          JSON.stringify(expected[key])
        }`,
      );
    }
  }
  return lines.join("\n");
}

const scoringConfig = parseScoringConfig(readJson("configs/scoring/v1.json"));

for (const profile of PROFILES) {
  Deno.test(`xval: golden vector ${profile}_1 reproduces exactly`, () => {
    const telemetry = parseGoldenTelemetry(
      readJson(`fixtures/golden/${profile}_1.telemetry.json`),
    );
    const expected = readJson(
      `fixtures/golden/${profile}_1.expected.json`,
    ) as Record<string, unknown>;

    const outcome = evaluate({
      gps: telemetry.gps,
      imu: telemetry.imu,
      route: telemetry.route,
      gates: telemetry.gates,
      benchmarkSeconds: telemetry.benchmarkSeconds,
      scoringConfig,
    });
    if (outcome === null) {
      throw new Error(`${profile}: pipeline returned null (degenerate course)`);
    }

    const actual = buildGoldenExpected(outcome) as unknown as Record<
      string,
      unknown
    >;
    if (!deepEqual(actual, expected)) {
      throw new Error(
        `golden vector mismatch for ${profile}_1:\n${
          describeMismatch(actual, expected)
        }\n` +
          `full actual:   ${JSON.stringify(actual)}\n` +
          `full expected: ${JSON.stringify(expected)}`,
      );
    }
  });
}
