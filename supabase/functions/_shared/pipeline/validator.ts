// Port of SmoooothKit SOCourse/CourseValidator.swift (spec §25).
// Cross-language determinism: every rule, threshold, and the exact issue
// collection order mirror the Swift reference; the shared contract fixtures
// (fixtures/contracts/course-validation.json) pin both sides — the server
// rejects everything the client rejects.

import { distanceMeters, type GeoCoordinate } from "./geo.ts";
import type { Checkpoint } from "./types.ts";
import { CourseMatcher } from "./course.ts";

/**
 * Limits for validating a course before it can be published. All limits
 * configurable — rejection thresholds are product decisions, not code
 * constants.
 */
export interface CourseValidationConfig {
  minDistanceMeters: number;
  maxDistanceMeters: number;
  /**
   * Route points further apart than this can hide geometry (rivers,
   * buildings) between them — the route is too coarse to validate.
   */
  maxPointSpacingMeters: number;
  /** Start + finish at minimum. */
  minCheckpoints: number;
  /** A checkpoint's center must sit within this distance of the route line. */
  maxCheckpointOffRouteMeters: number;
  /**
   * Consecutive checkpoints closer than this (along the course) make gates
   * meaningless.
   */
  minCheckpointSpacingMeters: number;
}

/** Mirrors Swift `CourseValidationConfig.default`. */
export const DEFAULT_COURSE_VALIDATION_CONFIG: CourseValidationConfig = {
  minDistanceMeters: 1_000,
  maxDistanceMeters: 80_000,
  maxPointSpacingMeters: 500,
  minCheckpoints: 2,
  maxCheckpointOffRouteMeters: 30,
  minCheckpointSpacingMeters: 200,
};

/**
 * One reason a course cannot be published. A validation run returns ALL
 * issues found, not just the first — creators fix everything in one pass.
 * `kind` strings are the camelCase Swift case names (contract-pinned).
 */
export type CourseValidationIssue =
  | { kind: "tooShort"; distanceMeters: number }
  | { kind: "tooLong"; distanceMeters: number }
  | { kind: "insufficientRoutePoints"; count: number }
  | { kind: "invalidCoordinate"; index: number }
  | { kind: "excessivePointSpacing"; index: number; meters: number }
  | { kind: "insufficientCheckpoints"; count: number }
  | { kind: "duplicateCheckpointSequence"; sequence: number }
  | { kind: "nonContiguousCheckpointSequence" }
  | { kind: "checkpointOffRoute"; sequence: number; meters: number }
  | { kind: "checkpointsOutOfOrder"; sequence: number }
  | { kind: "checkpointsTooClose"; sequence: number; meters: number }
  | { kind: "startNotAtRouteStart"; meters: number }
  | { kind: "finishNotAtRouteEnd"; meters: number };

/**
 * Validates course geometry + checkpoints before publishing (spec §25).
 * When any coordinate/point-count issue exists (or the geometry is
 * degenerate), returns early with only those issues — every later rule
 * needs a usable course line.
 */
export function validateCourse(
  polyline: readonly GeoCoordinate[],
  checkpoints: readonly Checkpoint[],
  config: CourseValidationConfig = DEFAULT_COURSE_VALIDATION_CONFIG,
): CourseValidationIssue[] {
  const issues: CourseValidationIssue[] = [];

  // ── Geometry ──────────────────────────────────────────────────────────
  if (polyline.length < 2) {
    issues.push({ kind: "insufficientRoutePoints", count: polyline.length });
  }
  for (let index = 0; index < polyline.length; index++) {
    const point = polyline[index];
    const latValid = Number.isFinite(point.latitude) &&
      Math.abs(point.latitude) <= 90;
    const lonValid = Number.isFinite(point.longitude) &&
      Math.abs(point.longitude) <= 180;
    if (!latValid || !lonValid) {
      issues.push({ kind: "invalidCoordinate", index });
    }
  }
  // Swift: `guard issues.isEmpty, let matcher = CourseMatcher(...)` — the
  // matcher is only attempted on clean coordinates.
  const matcher = issues.length === 0 ? CourseMatcher.create(polyline) : null;
  if (matcher === null) {
    return issues.length === 0
      ? [{ kind: "insufficientRoutePoints", count: polyline.length }]
      : issues;
  }

  const distance = matcher.totalDistanceMeters;
  if (distance < config.minDistanceMeters) {
    issues.push({ kind: "tooShort", distanceMeters: distance });
  }
  if (distance > config.maxDistanceMeters) {
    issues.push({ kind: "tooLong", distanceMeters: distance });
  }
  for (let index = 0; index + 1 < polyline.length; index++) {
    const spacing = distanceMeters(polyline[index], polyline[index + 1]);
    if (spacing > config.maxPointSpacingMeters) {
      issues.push({ kind: "excessivePointSpacing", index, meters: spacing });
    }
  }

  // ── Checkpoints ───────────────────────────────────────────────────────
  if (checkpoints.length < config.minCheckpoints) {
    issues.push({
      kind: "insufficientCheckpoints",
      count: checkpoints.length,
    });
  }
  // Stable sort by sequence (Swift sorted(by:) is stable; so is JS sort).
  const ordered = checkpoints.slice().sort((a, b) => a.sequence - b.sequence);
  const seenSequences = new Set<number>();
  for (const checkpoint of ordered) {
    if (seenSequences.has(checkpoint.sequence)) {
      issues.push({
        kind: "duplicateCheckpointSequence",
        sequence: checkpoint.sequence,
      });
    } else {
      seenSequences.add(checkpoint.sequence);
    }
  }
  if (
    ordered.length > 0 &&
    !ordered.every((checkpoint, index) => checkpoint.sequence === index)
  ) {
    issues.push({ kind: "nonContiguousCheckpointSequence" });
  }

  let previousAlongCourse = -Infinity;
  let previousSequence = -1;
  for (const checkpoint of ordered) {
    const match = matcher.nearestMatch(checkpoint.center);
    if (match.lateralOffsetMeters > config.maxCheckpointOffRouteMeters) {
      issues.push({
        kind: "checkpointOffRoute",
        sequence: checkpoint.sequence,
        meters: match.lateralOffsetMeters,
      });
      continue; // its course position is meaningless
    }
    if (match.distanceAlongCourseMeters < previousAlongCourse) {
      issues.push({
        kind: "checkpointsOutOfOrder",
        sequence: checkpoint.sequence,
      });
    } else if (previousSequence >= 0) {
      const spacing = match.distanceAlongCourseMeters - previousAlongCourse;
      if (spacing < config.minCheckpointSpacingMeters) {
        issues.push({
          kind: "checkpointsTooClose",
          sequence: checkpoint.sequence,
          meters: spacing,
        });
      }
    }
    previousAlongCourse = match.distanceAlongCourseMeters;
    previousSequence = checkpoint.sequence;

    if (checkpoint.sequence === 0) {
      const fromStart = match.distanceAlongCourseMeters;
      if (fromStart > checkpoint.radiusMeters * 2) {
        issues.push({ kind: "startNotAtRouteStart", meters: fromStart });
      }
    }
    if (checkpoint.sequence === ordered.length - 1) {
      const fromEnd = matcher.totalDistanceMeters -
        match.distanceAlongCourseMeters;
      if (fromEnd > checkpoint.radiusMeters * 2) {
        issues.push({ kind: "finishNotAtRouteEnd", meters: fromEnd });
      }
    }
  }

  return issues;
}
