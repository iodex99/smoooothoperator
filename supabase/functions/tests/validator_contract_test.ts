// Contract suite: the TS CourseValidator port must reproduce the Swift
// reference exactly on the pinned cases in fixtures/contracts/. Each case
// runs with the DEFAULT config; the sorted-unique set of issue kinds must
// equal `expectedIssues`. Never weaken the fixtures — they are pinned by
// the Swift reference implementation.
//
// Run: deno test --allow-read=../../fixtures,../../configs

import { validateCourse } from "../_shared/pipeline/validator.ts";
import type { GeoCoordinate } from "../_shared/pipeline/geo.ts";
import type { Checkpoint } from "../_shared/pipeline/types.ts";

interface ContractCase {
  name: string;
  /** [lat, lon] pairs. */
  polyline: number[][];
  /** [sequence, lat, lon, radiusMeters] rows. */
  checkpoints: number[][];
  expectedIssues: string[];
}

const repoRoot = new URL("../../../", import.meta.url);
const contract = JSON.parse(
  await Deno.readTextFile(
    new URL("fixtures/contracts/course-validation.json", repoRoot),
  ),
) as { formatVersion: number; cases: ContractCase[] };

function sortedUnique(kinds: readonly string[]): string[] {
  return [...new Set(kinds)].sort();
}

Deno.test("course-validation contract: fixture is complete", () => {
  if (contract.cases.length !== 12) {
    throw new Error(
      `expected 12 pinned contract cases, found ${contract.cases.length}`,
    );
  }
});

for (const contractCase of contract.cases) {
  Deno.test(`course-validation contract: ${contractCase.name}`, () => {
    const polyline: GeoCoordinate[] = contractCase.polyline.map((p) => ({
      latitude: p[0],
      longitude: p[1],
    }));
    const checkpoints: Checkpoint[] = contractCase.checkpoints.map((c) => ({
      sequence: c[0],
      center: { latitude: c[1], longitude: c[2] },
      radiusMeters: c[3],
    }));

    const issues = validateCourse(polyline, checkpoints);
    const got = sortedUnique(issues.map((issue) => issue.kind));
    const want = sortedUnique(contractCase.expectedIssues);
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      throw new Error(
        `${contractCase.name}: got [${got.join(", ")}] want [${
          want.join(", ")
        }]`,
      );
    }
  });
}
