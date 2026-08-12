// Port of SmoooothKit SOCore/GeoCoordinate.swift, GeoBearing.swift, Vector3.swift.
// Cross-language determinism (ADR-0002): every expression mirrors the Swift
// reference operation-for-operation, including evaluation order.

/** A WGS-84 latitude/longitude pair. */
export interface GeoCoordinate {
  latitude: number;
  longitude: number;
}

/** Mean Earth radius in meters (IUGG). */
export const EARTH_RADIUS_METERS = 6_371_008.8;

/** Great-circle distance in meters (haversine). */
export function distanceMeters(a: GeoCoordinate, b: GeoCoordinate): number {
  const lat1 = a.latitude * Math.PI / 180;
  const lat2 = b.latitude * Math.PI / 180;
  const dLat = (b.latitude - a.latitude) * Math.PI / 180;
  const dLon = (b.longitude - a.longitude) * Math.PI / 180;

  const h = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
  return EARTH_RADIUS_METERS * c;
}

/**
 * Initial great-circle bearing from `a` toward `b`, in degrees from true
 * north, normalized to 0..<360.
 */
export function bearingDegrees(a: GeoCoordinate, b: GeoCoordinate): number {
  const lat1 = a.latitude * Math.PI / 180;
  const lat2 = b.latitude * Math.PI / 180;
  const dLon = (b.longitude - a.longitude) * Math.PI / 180;

  const y = Math.sin(dLon) * Math.cos(lat2);
  const x = Math.cos(lat1) * Math.sin(lat2) -
    Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon);
  const radians = Math.atan2(y, x);
  const degrees = radians * 180 / Math.PI;
  // Swift truncatingRemainder == JS % (trunc-remainder).
  return (degrees + 360) % 360;
}

/**
 * The coordinate reached by traveling `distMeters` along the great circle
 * at `bearingDeg` from `from`.
 */
export function destination(
  from: GeoCoordinate,
  bearingDeg: number,
  distMeters: number,
): GeoCoordinate {
  const angular = distMeters / EARTH_RADIUS_METERS;
  const bearing = bearingDeg * Math.PI / 180;
  const lat1 = from.latitude * Math.PI / 180;
  const lon1 = from.longitude * Math.PI / 180;

  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(angular) +
      Math.cos(lat1) * Math.sin(angular) * Math.cos(bearing),
  );
  const lon2 = lon1 + Math.atan2(
    Math.sin(bearing) * Math.sin(angular) * Math.cos(lat1),
    Math.cos(angular) - Math.sin(lat1) * Math.sin(lat2),
  );
  return {
    latitude: lat2 * 180 / Math.PI,
    longitude: (lon2 * 180 / Math.PI + 540) % 360 - 180,
  };
}

// MARK: - Vector3

/** Minimal 3D vector for sensor-frame math. */
export interface Vector3 {
  x: number;
  y: number;
  z: number;
}

export const VECTOR3_ZERO: Vector3 = { x: 0, y: 0, z: 0 };

export function v3(x: number, y: number, z: number): Vector3 {
  return { x, y, z };
}

export function v3dot(a: Vector3, b: Vector3): number {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

export function v3cross(a: Vector3, b: Vector3): Vector3 {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  };
}

export function v3norm(a: Vector3): number {
  return Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
}

/** Unit vector in the same direction; null for (near-)zero vectors. */
export function v3normalized(a: Vector3, epsilon = 1e-12): Vector3 | null {
  const n = v3norm(a);
  if (!(n > epsilon)) return null;
  return { x: a.x / n, y: a.y / n, z: a.z / n };
}

export function v3scaled(a: Vector3, factor: number): Vector3 {
  return { x: a.x * factor, y: a.y * factor, z: a.z * factor };
}

export function v3add(a: Vector3, b: Vector3): Vector3 {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

export function v3sub(a: Vector3, b: Vector3): Vector3 {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

export function v3neg(a: Vector3): Vector3 {
  return { x: -a.x, y: -a.y, z: -a.z };
}
