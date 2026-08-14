// Start-line fairness, TypeScript side. This is the SERVER's opinion, and
// the server's verdict is the only one that ranks — so it must agree with
// the Swift reference exactly (ADR-0002).

import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  DEFAULT_INTEGRITY_CONFIG,
  evaluateRunIntegrity,
} from "../_shared/pipeline/integrity.ts";
import type { ProcessedTrajectory } from "../_shared/pipeline/types.ts";

/** Short, unremarkable trajectory: the check must not lean on anything else. */
function cleanTrajectory(): ProcessedTrajectory {
  const points = Array.from({ length: 20 }, (_, index) => ({
    timestamp: 1_000 + index,
    coordinate: { latitude: 34 + index * 0.00018, longitude: -118 },
    speedMps: 20,
    headingDegrees: 0,
    distanceAlongPathMeters: index * 20,
    horizontalAccuracy: 5,
  }));
  return { points, gaps: [], rejectedSampleCount: 0 };
}

function report(entrySpeed: number | null) {
  return evaluateRunIntegrity(
    [],
    [],
    cleanTrajectory(),
    null,
    null,
    DEFAULT_INTEGRITY_CONFIG,
    entrySpeed,
  );
}

Deno.test("a standing start is clean", () => {
  const result = report(0);
  assertFalse(result.findings.some((f) => f.flag === "flyingStart"));
  assertEquals(result.verdict, "verified");
});

Deno.test("a slow roll-up is allowed", () => {
  assertFalse(report(7).findings.some((f) => f.flag === "flyingStart"));
});

Deno.test("a flying start is caught and cannot rank", () => {
  const result = report(28);
  assert(result.findings.some((f) => f.flag === "flyingStart"));
  assertEquals(
    result.verdict,
    "questionable",
    "kept and scored, never ranked — unfairness, not fraud",
  );
});

Deno.test("the boundary matches the Swift reference exactly", () => {
  // Both implementations use `> limit`, not `>=`.
  assertFalse(report(8).findings.some((f) => f.flag === "flyingStart"));
  assert(report(8.01).findings.some((f) => f.flag === "flyingStart"));
});

Deno.test("the evidence string matches the Swift wording byte for byte", () => {
  // Swift: String(format: "crossed the start line at %.1f m/s (limit %.1f)")
  const finding = report(28).findings.find((f) => f.flag === "flyingStart");
  assertEquals(finding?.detail, "crossed the start line at 28.0 m/s (limit 8.0)");
  assertEquals(finding?.severity, "warning");
});

Deno.test("an unknown or non-finite crossing is not a finding", () => {
  for (const value of [null, NaN, Infinity]) {
    assertFalse(
      report(value).findings.some((f) => f.flag === "flyingStart"),
      `absence of data must not become an accusation (${value})`,
    );
  }
});

Deno.test("the ceiling is the same number on both sides", () => {
  // If this ever changes, the Swift IntegrityConfig default must change in
  // the same commit or the two scorers disagree.
  assertEquals(DEFAULT_INTEGRITY_CONFIG.maxStartEntrySpeedMps, 8);
});
