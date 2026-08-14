// Traffic and stopped time — the TypeScript half of the same rule.
//
// These mirror SmoooothKit/Tests/SOIntegrityTests/InterruptionTests.swift.
// The evidence strings are asserted byte-for-byte on both sides because
// golden vectors compare integrity findings: a wording difference here is a
// determinism failure, not a cosmetic one.

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  DEFAULT_INTEGRITY_CONFIG,
  evaluateRunIntegrity,
  stoppedSeconds,
} from "../_shared/pipeline/integrity.ts";
import type { ProcessedTrajectory, TrajectoryPoint } from "../_shared/pipeline/types.ts";

function trajectory(
  movingSeconds: number,
  stopped: number,
  speedMps = 20,
): ProcessedTrajectory {
  const points: TrajectoryPoint[] = [];
  let t = 0;
  let lat = 34.0;
  const push = (speed: number) => {
    points.push({
      timestamp: t,
      coordinate: { latitude: lat, longitude: -118.0 },
      speedMps: speed,
      headingDegrees: 90,
      distanceAlongPathMeters: 0,
      horizontalAccuracy: 5,
    });
  };
  while (t < movingSeconds / 2) {
    push(speedMps);
    lat += 0.00018;
    t += 0.1;
  }
  const stopUntil = t + stopped;
  while (t < stopUntil) {
    push(0);
    t += 0.1;
  }
  const driveUntil = t + movingSeconds / 2;
  while (t < driveUntil) {
    push(speedMps);
    lat += 0.00018;
    t += 0.1;
  }
  return { points, gaps: [], rejectedSampleCount: 0 };
}

function report(t: ProcessedTrajectory) {
  return evaluateRunIntegrity([], [], t, null, null);
}

Deno.test("stopped time is measured, not guessed", () => {
  const measured = stoppedSeconds(
    trajectory(100, 40),
    DEFAULT_INTEGRITY_CONFIG.stoppedSpeedMps,
  );
  assert(Math.abs(measured - 40) < 1, `measured ${measured}s, expected ~40`);
});

Deno.test("an uninterrupted run is not flagged", () => {
  const findings = report(trajectory(200, 0)).findings;
  assert(!findings.some((f) => f.flag === "heavilyInterrupted"));
});

Deno.test("a run stopped for most of its length cannot be ranked", () => {
  const result = report(trajectory(100, 90));
  const finding = result.findings.find((f) => f.flag === "heavilyInterrupted");
  assert(finding !== undefined, "a run stopped for half its length is not comparable");
  assertEquals(finding?.severity, "warning", "traffic is not cheating");
  assertEquals(result.verdict, "questionable", "kept and scored, never ranked");
});

Deno.test("one junction never gets a driver flagged", () => {
  // The absolute floor exists for exactly this: a label here would teach
  // drivers to run red lights.
  const findings = report(trajectory(40, 15)).findings;
  assert(!findings.some((f) => f.flag === "heavilyInterrupted"));
});

Deno.test("the evidence is byte-identical to the Swift reference", () => {
  const finding = report(trajectory(100, 90)).findings
    .find((f) => f.flag === "heavilyInterrupted");
  assertEquals(finding?.detail, "stopped for 90 s of 190 s (47% of the run)");
});

Deno.test("a lost signal is not a red light", () => {
  const points: TrajectoryPoint[] = [];
  for (let i = 0; i < 100; i++) {
    points.push({
      timestamp: i * 0.1,
      coordinate: { latitude: 34.0 + i * 0.00018, longitude: -118.0 },
      speedMps: 20, headingDegrees: 90,
      distanceAlongPathMeters: 0, horizontalAccuracy: 5,
    });
  }
  for (let i = 0; i < 100; i++) {
    points.push({
      timestamp: 70 + i * 0.1,
      coordinate: { latitude: 34.02 + i * 0.00018, longitude: -118.0 },
      speedMps: 20, headingDegrees: 90,
      distanceAlongPathMeters: 0, horizontalAccuracy: 5,
    });
  }
  const measured = stoppedSeconds(
    { points, gaps: [], rejectedSampleCount: 0 },
    DEFAULT_INTEGRITY_CONFIG.stoppedSpeedMps,
  );
  assertEquals(measured, 0, "a 60 s hole is a gap, not a queue");
});

Deno.test("a car braking to a stop is not counted as stopped yet", () => {
  const points: TrajectoryPoint[] = [
    { timestamp: 0, coordinate: { latitude: 34, longitude: -118 }, speedMps: 10,
      headingDegrees: 90, distanceAlongPathMeters: 0, horizontalAccuracy: 5 },
    { timestamp: 1, coordinate: { latitude: 34, longitude: -118 }, speedMps: 0,
      headingDegrees: 90, distanceAlongPathMeters: 0, horizontalAccuracy: 5 },
    { timestamp: 2, coordinate: { latitude: 34, longitude: -118 }, speedMps: 0,
      headingDegrees: 90, distanceAlongPathMeters: 0, horizontalAccuracy: 5 },
  ];
  assertEquals(
    stoppedSeconds({ points, gaps: [], rejectedSampleCount: 0 },
      DEFAULT_INTEGRITY_CONFIG.stoppedSpeedMps),
    1,
  );
});

Deno.test("the thresholds match the Swift defaults exactly", () => {
  assertEquals(DEFAULT_INTEGRITY_CONFIG.stoppedSpeedMps, 0.5);
  assertEquals(DEFAULT_INTEGRITY_CONFIG.maxStoppedFraction, 0.25);
  assertEquals(DEFAULT_INTEGRITY_CONFIG.minStoppedSecondsToFlag, 20);
});
