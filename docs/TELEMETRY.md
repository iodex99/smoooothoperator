# Telemetry

> Living document. L1 engines implemented — see modules in `SmoooothKit/Sources/SOTelemetry` and `SOSimulator`.

## Hard-won modeling truths (L1 integration findings)

1. **GPS position error is time-correlated.** Modeling it as independent
   per-fix noise makes reconstructed paths zig-zag and inflates distance ~2×
   at 10 Hz. The simulator uses an Ornstein–Uhlenbeck bias walk
   (σ≈1.5 m, τ≈60 s); any future noise reasoning must respect this.
2. **Never difference consecutive high-rate GPS speeds.** dv/dt between
   10 Hz fixes has σ≈2 m/s² from speed noise alone — sign flips destroy
   orientation evidence. The estimator uses anchored ≥0.8 s windows.
3. **A course without hairpins can't separate drivers.** Gentle sweepers never
   force braking, so smooth and aggressive look identical. Demo/synthetic
   courses need sharp-corner clusters (real courses: "23 meaningful turns").
4. **Mock GPS looks *too* clean**: metronome fix clock (honest receivers
   jitter by ms), zero accuracy variance, and a dead IMU while GPS claims
   motion. All three are integrity signals (L3).

## Pipeline (spec §22)

```
raw sensors → filtering → sensor fusion → trajectory reconstruction
            → map matching → event detection → scoring
```

Raw and processed telemetry are separate artifacts. Raw telemetry is never
destroyed, never mutated, and never publicly exposed.

## Sources

- **GPS (10 Hz target):** lat/lon, horizontal accuracy, altitude, course, speed, timestamp.
- **IMU (50 Hz target):** accelerometer + gyroscope XYZ in the device frame.
- Magnetometer/barometer: added where they earn their keep (later).

`LocationSource` / `MotionSource` protocols (`SOTelemetry/SensorSources.swift`)
are the seam: CoreLocation/CoreMotion adapters on iOS, synthetic profiles in
the simulator — identical pipeline downstream (spec §58).

## Vehicle orientation (spec §19)

Phones are mounted arbitrarily. During calibration (drive straight ~5 s), the
`VehicleOrientationEstimator` (L1) identifies the vehicle's forward/lateral/
vertical axes and transforms device-frame IMU into the vehicle frame
(longitudinal / lateral / vertical). Property-tested under randomized mount
rotations: the estimator must converge for any physically plausible mount.

## GPS quality (spec §21)

`LocationConfidenceScore` 0–100 from: horizontal accuracy, update frequency,
jumps, gaps, impossible movement, inertial consistency. Thresholds are
configurable; the app never claims GPS is perfectly accurate. Copy used in
product: "Verified using location and motion data."

## Recording durability (spec §60)

PLANNED (not yet built): in-flight samples appending to a crash-safe, length-prefixed file — no database in
the hot path. A completed run persists locally in the `SOSync` upload queue
(`pending → uploading → uploaded`, `failed → uploading` retry) and survives
connectivity loss, app kills, and phone calls. Never lose a completed run.
