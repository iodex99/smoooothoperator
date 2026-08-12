// Port of SmoooothKit SOTelemetry/DrivingEventDetector.swift.
// Centered TIME-window smoothing via two-pointer, hysteresis open/close,
// merge, then sort by (startTime, kind rawValue string) tuple — all
// operation orders preserved exactly.

import { curve, PiecewiseLinearCurve } from "./curve.ts";
import type {
  DrivingEvent,
  DrivingEventKind,
  ProcessedTrajectory,
  TrajectoryPoint,
  VehicleFrameSample,
} from "./types.ts";

/** Thresholds and smoothing for the detector (spec §37). */
export interface EventDetectionConfig {
  /** Positive longitudinal (throttle) event threshold, speed (m/s) → g. */
  accelerationThreshold: PiecewiseLinearCurve;
  /** Negative longitudinal (brake) event threshold. */
  brakingThreshold: PiecewiseLinearCurve;
  /** Peak level at which a braking event is classified hard. */
  hardBrakingThreshold: PiecewiseLinearCurve;
  /** |lateral| (cornering) event threshold. */
  corneringThreshold: PiecewiseLinearCurve;
  /** Peak level at which a cornering event is classified hard. */
  hardCorneringThreshold: PiecewiseLinearCurve;
  /** Width of the centered moving-average window, seconds. */
  smoothingWindowSeconds: number;
  /** Events shorter than this are discarded as noise, seconds. */
  minEventDurationSeconds: number;
  /** An open event closes below hysteresisRatio × threshold. */
  hysteresisRatio: number;
  /** Same-kind events separated by less than this merge into one, seconds. */
  mergeGapSeconds: number;
}

/** Spec §37 initial thresholds — mirrors Swift `EventDetectionConfig.default`. */
export const DEFAULT_EVENT_DETECTION_CONFIG: EventDetectionConfig = {
  accelerationThreshold: curve([[0, 0.30], [30, 0.25]]),
  brakingThreshold: curve([[0, 0.25]]),
  hardBrakingThreshold: curve([[3, 0.45], [15, 0.35], [30, 0.30]]),
  corneringThreshold: curve([[0, 0.30]]),
  hardCorneringThreshold: curve([[3, 0.50], [15, 0.42], [30, 0.38]]),
  smoothingWindowSeconds: 0.5,
  minEventDurationSeconds: 0.3,
  hysteresisRatio: 0.8,
  mergeGapSeconds: 0.5,
};

/** Linear speed interpolation over trajectory points (binary search). */
class SpeedInterpolator {
  private readonly points: TrajectoryPoint[];

  constructor(trajectory: ProcessedTrajectory | null) {
    this.points = trajectory !== null ? trajectory.points : [];
  }

  speedAt(time: number): number | null {
    if (this.points.length === 0) return null;
    const first = this.points[0];
    const last = this.points[this.points.length - 1];
    if (time <= first.timestamp) return first.speedMps;
    if (time >= last.timestamp) return last.speedMps;

    let low = 0;
    let high = this.points.length - 1;
    while (high - low > 1) {
      const mid = Math.trunc((low + high) / 2);
      if (this.points[mid].timestamp <= time) {
        low = mid;
      } else {
        high = mid;
      }
    }
    const a = this.points[low];
    const b = this.points[high];
    const span = b.timestamp - a.timestamp;
    if (!(span > 0)) return a.speedMps;
    const t = (time - a.timestamp) / span;
    return a.speedMps + t * (b.speedMps - a.speedMps);
  }
}

/**
 * Centered moving average over a time window (not a sample count).
 * Two-pointer accumulation order matches the Swift reference exactly —
 * floating-point addition is not associative.
 */
function smooth(
  values: readonly number[],
  times: readonly number[],
  smoothingWindowSeconds: number,
): number[] {
  const halfWindow = smoothingWindowSeconds / 2;
  if (!(halfWindow > 0)) return values.slice();

  const smoothed: number[] = [];
  let lower = 0;
  let upper = 0;
  let windowSum = 0;

  for (let index = 0; index < values.length; index++) {
    const center = times[index];
    while (upper < values.length && times[upper] <= center + halfWindow) {
      windowSum += values[upper];
      upper += 1;
    }
    while (lower < upper && times[lower] < center - halfWindow) {
      windowSum -= values[lower];
      lower += 1;
    }
    smoothed.push(windowSum / (upper - lower));
  }
  return smoothed;
}

interface OpenEvent {
  startTime: number;
  peak: number;
  peakSpeed: number | null;
}

/** Hysteresis segmentation of one non-negative signal. */
function segment(
  signal: readonly number[],
  times: readonly number[],
  speeds: SpeedInterpolator,
  openCurve: PiecewiseLinearCurve,
  hardCurve: PiecewiseLinearCurve | null,
  normalKind: DrivingEventKind,
  hardKind: DrivingEventKind | null,
  config: EventDetectionConfig,
): DrivingEvent[] {
  const events: DrivingEvent[] = [];
  let open: OpenEvent | null = null;

  const close = (event: OpenEvent, endTime: number): void => {
    if (!(endTime - event.startTime >= config.minEventDurationSeconds)) return;
    let kind = normalKind;
    if (
      hardCurve !== null && hardKind !== null &&
      event.peak >= hardCurve.valueAt(event.peakSpeed ?? 0)
    ) {
      kind = hardKind;
    }
    events.push({
      kind,
      startTime: event.startTime,
      endTime,
      peakMagnitudeG: event.peak,
      speedAtPeakMps: event.peakSpeed,
    });
  };

  for (let index = 0; index < signal.length; index++) {
    const time = times[index];
    const speed = speeds.speedAt(time);
    const threshold = openCurve.valueAt(speed ?? 0);
    const value = signal[index];

    if (open !== null) {
      if (value >= config.hysteresisRatio * threshold) {
        if (value > open.peak) {
          open.peak = value;
          open.peakSpeed = speed;
        }
      } else {
        close(open, time);
        open = null;
      }
    } else if (value >= threshold) {
      open = { startTime: time, peak: value, peakSpeed: speed };
    }
  }
  if (open !== null && times.length > 0) {
    close(open, times[times.length - 1]);
  }
  return events;
}

/**
 * Merges same-kind events separated by less than mergeGapSeconds, keeping
 * the strongest peak. Stable sort by startTime (Swift sorted(by:) is stable;
 * so is JS Array.prototype.sort).
 */
function merge(
  events: readonly DrivingEvent[],
  config: EventDetectionConfig,
): DrivingEvent[] {
  const merged: DrivingEvent[] = [];
  const byStart = events.slice().sort((a, b) => a.startTime - b.startTime);
  for (const event of byStart) {
    const last = merged.length > 0 ? merged[merged.length - 1] : null;
    if (
      last !== null && last.kind === event.kind &&
      event.startTime - last.endTime < config.mergeGapSeconds
    ) {
      last.endTime = Math.max(last.endTime, event.endTime);
      if (event.peakMagnitudeG > last.peakMagnitudeG) {
        last.peakMagnitudeG = event.peakMagnitudeG;
        last.speedAtPeakMps = event.speedAtPeakMps;
      }
    } else {
      merged.push({ ...event });
    }
  }
  return merged;
}

/**
 * Detects events. `samples` must be in timestamp order. When `trajectory`
 * is null, speed is unknown and every threshold curve is evaluated at 0.
 */
export function detectDrivingEvents(
  samples: readonly VehicleFrameSample[],
  trajectory: ProcessedTrajectory | null,
  config: EventDetectionConfig = DEFAULT_EVENT_DETECTION_CONFIG,
): DrivingEvent[] {
  if (!(samples.length > 1)) return [];

  const times = samples.map((s) => s.timestamp);
  const longitudinal = smooth(
    samples.map((s) => s.longitudinal),
    times,
    config.smoothingWindowSeconds,
  );
  const lateral = smooth(
    samples.map((s) => s.lateral),
    times,
    config.smoothingWindowSeconds,
  );
  const speeds = new SpeedInterpolator(trajectory);

  let events: DrivingEvent[] = [];
  // Throttle: positive longitudinal only.
  events = events.concat(segment(
    longitudinal.map((v) => Math.max(0, v)),
    times,
    speeds,
    config.accelerationThreshold,
    null,
    "acceleration",
    null,
    config,
  ));
  // Brake: negative longitudinal, folded to magnitude.
  events = events.concat(segment(
    longitudinal.map((v) => Math.max(0, -v)),
    times,
    speeds,
    config.brakingThreshold,
    config.hardBrakingThreshold,
    "braking",
    "hardBraking",
    config,
  ));
  // Cornering: |lateral|, either direction.
  events = events.concat(segment(
    lateral.map((v) => Math.abs(v)),
    times,
    speeds,
    config.corneringThreshold,
    config.hardCorneringThreshold,
    "cornering",
    "hardCornering",
    config,
  ));

  // Swift tuple sort: (startTime, kind.rawValue) with ASCII string compare.
  return merge(events, config).sort((a, b) => {
    if (a.startTime !== b.startTime) return a.startTime < b.startTime ? -1 : 1;
    return a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : 0;
  });
}
