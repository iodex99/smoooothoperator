// Shared pipeline types — ports of SmoooothKit SOTelemetry/Samples.swift,
// Trajectory.swift, VehicleFrame.swift, SOCourse/Checkpoint.swift,
// SOCourse/Providers.swift (SpeedLimitSegment), SOTelemetry/DrivingEventDetector.swift
// (kinds/events), SOIntegrity/IntegrityFlag.swift, SOModels/RunVerificationStatus.swift.
//
// Swift `Optional` maps to `T | null` everywhere (never `undefined`).

import { distanceMeters, type GeoCoordinate } from "./geo.ts";

/** One GPS fix as delivered by the platform location source. */
export interface GPSSample {
  /** Seconds since Unix epoch. */
  timestamp: number;
  coordinate: GeoCoordinate;
  /** Meters above sea level; null when the fix has no altitude. */
  altitude: number | null;
  /** 1-sigma horizontal error estimate in meters; negative means invalid fix. */
  horizontalAccuracy: number;
  /** Direction of travel in degrees from true north (0..<360); null when unknown. */
  course: number | null;
  /** Ground speed in m/s; null when unknown. */
  speed: number | null;
}

/** One inertial sample (accelerometer + gyroscope) in the *device* frame. */
export interface IMUSample {
  /** Seconds since Unix epoch. */
  timestamp: number;
  /** Acceleration in g, device axes. */
  accelX: number;
  accelY: number;
  accelZ: number;
  /** Rotation rate in rad/s, device axes. */
  gyroX: number;
  gyroY: number;
  gyroZ: number;
}

/** One cleaned, filtered point of a reconstructed trajectory. */
export interface TrajectoryPoint {
  timestamp: number;
  coordinate: GeoCoordinate;
  /** Filtered ground speed, m/s (never negative). */
  speedMps: number;
  /** Direction of travel in degrees from true north; null while unknown. */
  headingDegrees: number | null;
  /** Cumulative distance from the first point, meters (non-decreasing). */
  distanceAlongPathMeters: number;
  /** Accuracy of the underlying fix, meters. */
  horizontalAccuracy: number;
}

export type TelemetryGapReason = "noSamples" | "rejectedSamples";

/** A window of missing/unusable data discovered during processing. */
export interface TelemetryGap {
  startTime: number;
  endTime: number;
  reason: TelemetryGapReason;
}

export function gapDuration(gap: TelemetryGap): number {
  return gap.endTime - gap.startTime;
}

/** The reconstructed path of a run. */
export interface ProcessedTrajectory {
  points: TrajectoryPoint[];
  gaps: TelemetryGap[];
  /** Count of raw samples rejected by filtering. */
  rejectedSampleCount: number;
}

export function trajectoryTotalDistanceMeters(t: ProcessedTrajectory): number {
  return t.points.length > 0
    ? t.points[t.points.length - 1].distanceAlongPathMeters
    : 0;
}

export function trajectoryDuration(t: ProcessedTrajectory): number {
  if (t.points.length === 0) return 0;
  return t.points[t.points.length - 1].timestamp - t.points[0].timestamp;
}

/** One inertial sample transformed into the *vehicle* frame. */
export interface VehicleFrameSample {
  timestamp: number;
  /** Forward(+)/backward(−) acceleration in g, gravity-removed. */
  longitudinal: number;
  /** Right(+)/left(−) acceleration in g, gravity-removed. */
  lateral: number;
  /** Up(+)/down(−) acceleration in g, gravity-removed. */
  vertical: number;
  /** Rotation rate about the vehicle's vertical axis in rad/s. */
  yawRate: number;
}

/** An ordered gate on a course: start, intermediate checkpoints, finish. */
export interface Checkpoint {
  /** Position in the course's checkpoint ordering (0 = start). */
  sequence: number;
  center: GeoCoordinate;
  radiusMeters: number;
}

/** Whether a GPS fix falls inside this checkpoint's gate radius. */
export function checkpointContains(
  checkpoint: Checkpoint,
  coordinate: GeoCoordinate,
): boolean {
  return distanceMeters(checkpoint.center, coordinate) <=
    checkpoint.radiusMeters;
}

/** Kinds of notable driving events. Raw values persisted — never change. */
export type DrivingEventKind =
  | "acceleration"
  | "braking"
  | "hardBraking"
  | "cornering"
  | "hardCornering";

/** One detected driving event. */
export interface DrivingEvent {
  kind: DrivingEventKind;
  startTime: number;
  endTime: number;
  /** Absolute value of the peak *smoothed* signal during the event, in g. */
  peakMagnitudeG: number;
  /** Interpolated ground speed at the peak; null when no trajectory was given. */
  speedAtPeakMps: number | null;
}

/**
 * A stretch of course with a known legal speed limit. `limitMps` null means
 * no reliable data — compliance scoring must NOT infer violations there.
 */
export interface SpeedLimitSegment {
  startDistanceMeters: number;
  endDistanceMeters: number;
  limitMps: number | null;
}

/** Anti-cheat / data-quality signals. Raw values persisted — never change. */
export type IntegrityFlag =
  | "mockLocation"
  | "gpsReplay"
  | "impossibleSpeed"
  | "impossibleAcceleration"
  | "timestampAnomaly"
  | "routeSkip"
  | "gpsJump"
  | "sensorMismatch"
  | "suspiciousGap"
  | "deviceIntegrity";

/** Verification outcome of a run. Raw values persisted — never change. */
export type RunVerificationStatus = "verified" | "questionable" | "invalid";
