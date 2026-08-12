// Port of SmoooothKit SOCourse/CourseMatcher.swift + CourseProgressTracker.swift.
// Local equirectangular projection, whole-course vs windowed matching, monotone
// progress, in-order checkpoint gating, deviation detection.

import type { GeoCoordinate } from "./geo.ts";
import {
  type Checkpoint,
  checkpointContains,
  type ProcessedTrajectory,
  type TrajectoryPoint,
} from "./types.ts";

/** A fix matched against the course line. */
export interface CourseMatch {
  /** Distance along the course of the closest on-course point, meters. */
  distanceAlongCourseMeters: number;
  /** Unsigned distance from the fix to the course line, meters. */
  lateralOffsetMeters: number;
  /** Index of the polyline segment the match landed on. */
  segmentIndex: number;
}

interface Segment {
  startX: number;
  startY: number;
  deltaX: number;
  deltaY: number;
  lengthSquared: number;
  /** Course distance at the segment start, meters. */
  startDistance: number;
  length: number;
}

const METERS_PER_DEGREE = 111_195.0;

/**
 * Geometric matcher against a course polyline. Construct via
 * `CourseMatcher.create` — returns null on degenerate polylines
 * (<2 points or zero length), mirroring the Swift failable init.
 */
export class CourseMatcher {
  private readonly segments: Segment[];
  private readonly originLatitude: number;
  private readonly originLongitude: number;
  private readonly cosLatitude: number;
  readonly totalDistanceMeters: number;

  private constructor(
    segments: Segment[],
    originLatitude: number,
    originLongitude: number,
    cosLatitude: number,
    totalDistanceMeters: number,
  ) {
    this.segments = segments;
    this.originLatitude = originLatitude;
    this.originLongitude = originLongitude;
    this.cosLatitude = cosLatitude;
    this.totalDistanceMeters = totalDistanceMeters;
  }

  static create(polyline: readonly GeoCoordinate[]): CourseMatcher | null {
    if (polyline.length < 2) return null;
    const origin = polyline[0];
    const originLatitude = origin.latitude;
    const originLongitude = origin.longitude;
    const cosLatitude = Math.cos(origin.latitude * Math.PI / 180);

    const project = (coordinate: GeoCoordinate): { x: number; y: number } => ({
      x: (coordinate.longitude - origin.longitude) * METERS_PER_DEGREE *
        Math.cos(origin.latitude * Math.PI / 180),
      y: (coordinate.latitude - origin.latitude) * METERS_PER_DEGREE,
    });

    const built: Segment[] = [];
    let cumulative = 0;
    for (let i = 1; i < polyline.length; i++) {
      const pa = project(polyline[i - 1]);
      const pb = project(polyline[i]);
      const dx = pb.x - pa.x;
      const dy = pb.y - pa.y;
      const lengthSquared = dx * dx + dy * dy;
      const length = Math.sqrt(lengthSquared);
      if (!(length > 0)) continue; // skip duplicate points
      built.push({
        startX: pa.x,
        startY: pa.y,
        deltaX: dx,
        deltaY: dy,
        lengthSquared,
        startDistance: cumulative,
        length,
      });
      cumulative += length;
    }
    if (!(cumulative > 0)) return null;
    return new CourseMatcher(
      built,
      originLatitude,
      originLongitude,
      cosLatitude,
      cumulative,
    );
  }

  /** Closest match across the entire course. */
  nearestMatch(coordinate: GeoCoordinate): CourseMatch {
    return this.matchRange(coordinate, 0, this.segments.length - 1);
  }

  /** Closest match within a course-distance window around `cursorMeters`. */
  matchNear(
    coordinate: GeoCoordinate,
    cursorMeters: number,
    backtrackMeters = 100,
    lookaheadMeters = 400,
  ): CourseMatch {
    const lower = cursorMeters - backtrackMeters;
    const upper = cursorMeters + lookaheadMeters;
    let first = this.segments.length - 1;
    let last = 0;
    for (let index = 0; index < this.segments.length; index++) {
      const segment = this.segments[index];
      const segmentEnd = segment.startDistance + segment.length;
      if (segmentEnd >= lower && segment.startDistance <= upper) {
        first = Math.min(first, index);
        last = Math.max(last, index);
      }
    }
    if (!(first <= last)) return this.nearestMatch(coordinate);
    return this.matchRange(coordinate, first, last);
  }

  /** Match over segment indices first...last (inclusive). */
  private matchRange(
    coordinate: GeoCoordinate,
    first: number,
    last: number,
  ): CourseMatch {
    const x = (coordinate.longitude - this.originLongitude) *
      METERS_PER_DEGREE *
      this.cosLatitude;
    const y = (coordinate.latitude - this.originLatitude) * METERS_PER_DEGREE;

    let best: CourseMatch = {
      distanceAlongCourseMeters: 0,
      lateralOffsetMeters: Infinity,
      segmentIndex: 0,
    };
    for (let index = first; index <= last; index++) {
      const segment = this.segments[index];
      const relX = x - segment.startX;
      const relY = y - segment.startY;
      const t = Math.min(
        1,
        Math.max(
          0,
          (relX * segment.deltaX + relY * segment.deltaY) /
            segment.lengthSquared,
        ),
      );
      const closestX = segment.startX + t * segment.deltaX;
      const closestY = segment.startY + t * segment.deltaY;
      const offsetX = x - closestX;
      const offsetY = y - closestY;
      const offset = Math.sqrt(offsetX * offsetX + offsetY * offsetY);
      if (offset < best.lateralOffsetMeters) {
        best = {
          distanceAlongCourseMeters: segment.startDistance + t * segment.length,
          lateralOffsetMeters: offset,
          segmentIndex: index,
        };
      }
    }
    return best;
  }
}

/** Thresholds for live course tracking. */
export interface CourseProgressConfig {
  corridorWidthMeters: number;
  deviationGraceSeconds: number;
  backtrackMeters: number;
  lookaheadMeters: number;
}

/** Mirrors Swift `CourseProgressConfig.default`. */
export const DEFAULT_COURSE_PROGRESS_CONFIG: CourseProgressConfig = {
  corridorWidthMeters: 40,
  deviationGraceSeconds: 5,
  backtrackMeters: 100,
  lookaheadMeters: 400,
};

/** A checkpoint gate passed in order. */
export interface CheckpointHit {
  sequence: number;
  timestamp: number;
  progressMeters: number;
}

/** A continuous window spent outside the course corridor. */
export interface OffCourseExcursion {
  startTime: number;
  endTime: number;
  maxLateralOffsetMeters: number;
}

/**
 * Live course tracking: monotone progress, in-order checkpoint gating,
 * off-course/deviation detection. Construct via `CourseProgressTracker.create`
 * — returns null on degenerate course geometry.
 */
export class CourseProgressTracker {
  readonly config: CourseProgressConfig;
  private readonly matcher: CourseMatcher;
  private readonly checkpoints: Checkpoint[];

  /** Monotone course progress, meters. */
  progressMeters = 0;
  /** Gates passed so far, in order. */
  checkpointHits: CheckpointHit[] = [];
  /** Closed off-course windows. */
  offCourseExcursions: OffCourseExcursion[] = [];
  isOffCourse = false;

  private openExcursionStart: number | null = null;
  private openExcursionMaxOffset = 0;
  private lastIngestTimestamp: number | null = null;

  private constructor(
    matcher: CourseMatcher,
    checkpoints: Checkpoint[],
    config: CourseProgressConfig,
  ) {
    this.matcher = matcher;
    this.checkpoints = checkpoints;
    this.config = config;
  }

  static create(
    polyline: readonly GeoCoordinate[],
    checkpoints: readonly Checkpoint[],
    config: CourseProgressConfig = DEFAULT_COURSE_PROGRESS_CONFIG,
  ): CourseProgressTracker | null {
    const matcher = CourseMatcher.create(polyline);
    if (matcher === null) return null;
    // Stable sort by sequence (Swift sorted(by:) is stable; so is JS sort).
    const sorted = checkpoints.slice().sort((a, b) => a.sequence - b.sequence);
    return new CourseProgressTracker(matcher, sorted, config);
  }

  get totalDistanceMeters(): number {
    return this.matcher.totalDistanceMeters;
  }

  /** Course progress normalized to 0...1. */
  get progressFraction(): number {
    return this.matcher.totalDistanceMeters > 0
      ? Math.min(1, this.progressMeters / this.matcher.totalDistanceMeters)
      : 0;
  }

  /** The next gate the driver must pass, or null when all are hit. */
  get nextCheckpoint(): Checkpoint | null {
    return this.checkpointHits.length < this.checkpoints.length
      ? this.checkpoints[this.checkpointHits.length]
      : null;
  }

  /** All gates (including the finish) passed in order. */
  get hasFinished(): boolean {
    return this.checkpoints.length > 0 &&
      this.checkpointHits.length === this.checkpoints.length;
  }

  /**
   * True once any excursion exceeded the deviation grace. An excursion still
   * open at the last ingested fix counts.
   */
  get deviationDetected(): boolean {
    if (
      this.offCourseExcursions.some(
        (e) => e.endTime - e.startTime > this.config.deviationGraceSeconds,
      )
    ) {
      return true;
    }
    if (this.openExcursionStart !== null && this.lastIngestTimestamp !== null) {
      return this.lastIngestTimestamp - this.openExcursionStart >
        this.config.deviationGraceSeconds;
    }
    return false;
  }

  ingestPoint(point: TrajectoryPoint): void {
    this.lastIngestTimestamp = point.timestamp;

    // "Am I on the course at all?" — judged against the WHOLE course.
    // "Where along the course am I?" — judged inside the cursor window.
    const global = this.matcher.nearestMatch(point.coordinate);
    const windowed = this.matcher.matchNear(
      point.coordinate,
      this.progressMeters,
      this.config.backtrackMeters,
      this.config.lookaheadMeters,
    );

    if (global.lateralOffsetMeters <= this.config.corridorWidthMeters) {
      if (this.openExcursionStart !== null) {
        this.offCourseExcursions.push({
          startTime: this.openExcursionStart,
          endTime: point.timestamp,
          maxLateralOffsetMeters: this.openExcursionMaxOffset,
        });
        this.openExcursionStart = null;
        this.openExcursionMaxOffset = 0;
      }
      this.isOffCourse = false;
      // Progress advances only when the windowed match agrees.
      if (windowed.lateralOffsetMeters <= this.config.corridorWidthMeters) {
        this.progressMeters = Math.max(
          this.progressMeters,
          windowed.distanceAlongCourseMeters,
        );
      }
    } else {
      if (this.openExcursionStart === null) {
        this.openExcursionStart = point.timestamp;
      }
      this.openExcursionMaxOffset = Math.max(
        this.openExcursionMaxOffset,
        global.lateralOffsetMeters,
      );
      this.isOffCourse = true;
    }

    // Gate the next expected checkpoint only.
    const next = this.nextCheckpoint;
    if (next !== null && checkpointContains(next, point.coordinate)) {
      this.checkpointHits.push({
        sequence: next.sequence,
        timestamp: point.timestamp,
        progressMeters: this.progressMeters,
      });
    }
  }

  /** Convenience: run a whole processed trajectory through the tracker. */
  ingestTrajectory(trajectory: ProcessedTrajectory): void {
    for (const point of trajectory.points) {
      this.ingestPoint(point);
    }
  }
}
