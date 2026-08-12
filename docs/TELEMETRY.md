# Telemetry

> Living document. Grows substantially in Phase L1.

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

In-flight samples append to a crash-safe, length-prefixed file — no database in
the hot path. A completed run persists locally in the `SOSync` upload queue
(`pending → uploading → uploaded`, `failed → uploading` retry) and survives
connectivity loss, app kills, and phone calls. Never lose a completed run.
