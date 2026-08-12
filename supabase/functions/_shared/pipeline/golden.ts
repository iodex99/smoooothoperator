// Port of SmoooothKit SOSimulator/GoldenVector.swift wire formats:
// GoldenTelemetry (compact arrays; sentinel -9999 = null) and GoldenExpected
// (the discrete pipeline outputs a golden vector pins).

import type { GeoCoordinate } from "./geo.ts";
import type { Checkpoint, GPSSample, IMUSample } from "./types.ts";
import type { PipelineOutcome } from "./pipeline.ts";

/** Sentinel for "nil" in numeric array slots (never a legal value there). */
const ABSENT = -9999;

/** One golden telemetry vector: the full raw input of a simulated run. */
export interface GoldenTelemetry {
  formatVersion: number;
  profile: string;
  seed: number;
  benchmarkSeconds: number;
  route: GeoCoordinate[];
  gates: Checkpoint[];
  gps: GPSSample[];
  imu: IMUSample[];
}

function asNumber(value: unknown, path: string): number {
  if (typeof value !== "number") {
    throw new Error(`golden telemetry: ${path} must be a number`);
  }
  return value;
}

function asNumberArrays(
  value: unknown,
  path: string,
  width: number,
): number[][] {
  if (!Array.isArray(value)) {
    throw new Error(`golden telemetry: ${path} must be an array`);
  }
  return value.map((row, i) => {
    if (!Array.isArray(row) || row.length < width) {
      throw new Error(
        `golden telemetry: ${path}[${i}] must be an array of ${width} numbers`,
      );
    }
    return row.map((v, j) => asNumber(v, `${path}[${i}][${j}]`));
  });
}

/**
 * Parses the GoldenTelemetry wire format:
 * route [[lat,lon]], gates [[seq,lat,lon,radius]],
 * gps [[t,lat,lon,accuracy,course,speed,alt]] with -9999 meaning null for
 * course/speed/alt, imu [[t,ax,ay,az,gx,gy,gz]].
 */
export function parseGoldenTelemetry(json: unknown): GoldenTelemetry {
  if (typeof json !== "object" || json === null) {
    throw new Error("golden telemetry: root must be an object");
  }
  const root = json as Record<string, unknown>;

  const route: GeoCoordinate[] = asNumberArrays(root.route, "route", 2).map(
    (r) => ({ latitude: r[0], longitude: r[1] }),
  );
  const gates: Checkpoint[] = asNumberArrays(root.gates, "gates", 4).map(
    (g) => ({
      sequence: Math.trunc(g[0]),
      center: { latitude: g[1], longitude: g[2] },
      radiusMeters: g[3],
    }),
  );
  const gps: GPSSample[] = asNumberArrays(root.gps, "gps", 7).map((s) => ({
    timestamp: s[0],
    coordinate: { latitude: s[1], longitude: s[2] },
    horizontalAccuracy: s[3],
    course: s[4] === ABSENT ? null : s[4],
    speed: s[5] === ABSENT ? null : s[5],
    altitude: s[6] === ABSENT ? null : s[6],
  }));
  const imu: IMUSample[] = asNumberArrays(root.imu, "imu", 7).map((s) => ({
    timestamp: s[0],
    accelX: s[1],
    accelY: s[2],
    accelZ: s[3],
    gyroX: s[4],
    gyroY: s[5],
    gyroZ: s[6],
  }));

  return {
    formatVersion: asNumber(root.formatVersion, "formatVersion"),
    profile: String(root.profile),
    seed: asNumber(root.seed, "seed"),
    benchmarkSeconds: asNumber(root.benchmarkSeconds, "benchmarkSeconds"),
    route,
    gates,
    gps,
    imu,
  };
}

/**
 * The discrete pipeline outputs a golden vector pins. Every field is an
 * integer, string, or bool — byte-exact comparable across Swift and TS.
 */
export interface GoldenExpected {
  scoringVersion: string;
  verdict: string;
  finalScore: number;
  paceBps: number;
  smoothnessBps: number;
  controlBps: number;
  complianceBps: number;
  confidenceScore: number;
  /** Event counts keyed by DrivingEventKind raw value. */
  eventCounts: Record<string, number>;
  /** Sorted, de-duplicated integrity flags. */
  flags: string[];
  gatesHit: number;
  deviationDetected: boolean;
  hasComplianceData: boolean;
}

/** Builds a GoldenExpected from a pipeline outcome — mirrors the Swift init. */
export function buildGoldenExpected(outcome: PipelineOutcome): GoldenExpected {
  const eventCounts: Record<string, number> = {};
  for (const event of outcome.events) {
    eventCounts[event.kind] = (eventCounts[event.kind] ?? 0) + 1;
  }
  // Swift `[String].sorted()` on ASCII flag names == JS default `.sort()`.
  const flags = [...new Set(outcome.integrity.findings.map((f) => f.flag))]
    .sort();

  return {
    scoringVersion: outcome.score.scoringVersion,
    verdict: outcome.integrity.verdict,
    finalScore: outcome.score.finalScore,
    paceBps: outcome.score.breakdown.paceBps,
    smoothnessBps: outcome.score.breakdown.smoothnessBps,
    controlBps: outcome.score.breakdown.controlBps,
    complianceBps: outcome.score.breakdown.complianceBps,
    confidenceScore: outcome.confidence.score,
    eventCounts,
    flags,
    gatesHit: outcome.gatesHit,
    deviationDetected: outcome.deviationDetected,
    hasComplianceData: outcome.score.hasComplianceData,
  };
}
