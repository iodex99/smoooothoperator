// validate-course — the only door into the course catalog (spec §§25-26, 67).
//
// Flow: Pro entitlement gate (custom course creation is Pro, spec §26) →
// server-side validation with the SAME rules the client ran (contract-pinned
// against the Swift reference) → derive catalog fields (distance, turn count,
// estimated duration) → service-role INSERT of the course + its checkpoint
// gates. Clients are read-only on both tables, so unvalidated geometry can
// never enter the catalog.
//
// The handler core is exported so integration tests can drive it against a
// local stack without the edge runtime; Deno.serve wires it for deploys.

import {
  bearingDegrees,
  distanceMeters,
  type GeoCoordinate,
} from "../_shared/pipeline/geo.ts";
import type { Checkpoint } from "../_shared/pipeline/types.ts";
import { CourseMatcher } from "../_shared/pipeline/course.ts";
import { validateCourse } from "../_shared/pipeline/validator.ts";

export interface ValidateCourseDeps {
  /** PostgREST base URL, e.g. http://127.0.0.1:54321/rest/v1 */
  restUrl: string;
  serviceKey: string;
}

export interface ValidateCoursePayload {
  name: string;
  description?: string;
  /** ISO 3166-1 alpha-2, e.g. "US". */
  country?: string;
  visibility: "public" | "friends" | "private";
  /** Route as [lat, lon] pairs. */
  polyline: [number, number][];
  /** Gates as [sequence, lat, lon, radiusMeters] rows. */
  checkpoints: [number, number, number, number][];
  /** 1-5; defaults to 1. */
  difficulty?: number;
}

const VISIBILITIES = new Set(["public", "friends", "private"]);

/** Structural sanity only — course *rules* live in the shared validator. */
function shapeError(payload: ValidateCoursePayload): string | null {
  if (typeof payload !== "object" || payload === null) {
    return "payload must be a JSON object";
  }
  if (typeof payload.name !== "string") return "name required";
  if (
    payload.description !== undefined && typeof payload.description !== "string"
  ) {
    return "description must be a string";
  }
  if (payload.country !== undefined && typeof payload.country !== "string") {
    return "country must be a string";
  }
  if (!VISIBILITIES.has(payload.visibility)) {
    return "visibility must be public|friends|private";
  }
  if (
    !Array.isArray(payload.polyline) ||
    payload.polyline.some(
      (p) =>
        !Array.isArray(p) || p.length !== 2 ||
        p.some((v) => typeof v !== "number"),
    )
  ) {
    return "polyline must be [lat, lon][]";
  }
  if (
    !Array.isArray(payload.checkpoints) ||
    payload.checkpoints.some(
      (c) =>
        !Array.isArray(c) || c.length !== 4 ||
        c.some((v) => typeof v !== "number"),
    )
  ) {
    return "checkpoints must be [sequence, lat, lon, radiusMeters][]";
  }
  if (
    payload.difficulty !== undefined &&
    (!Number.isInteger(payload.difficulty) || payload.difficulty < 1 ||
      payload.difficulty > 5)
  ) {
    return "difficulty must be an integer 1-5";
  }
  return null;
}

/**
 * Heading changes above 25° between consecutive route segments count as
 * turns. Zero-length segments carry no heading and are skipped.
 */
function countTurns(
  polyline: readonly GeoCoordinate[],
  thresholdDegrees = 25,
): number {
  const bearings: number[] = [];
  for (let i = 1; i < polyline.length; i++) {
    if (distanceMeters(polyline[i - 1], polyline[i]) > 0) {
      bearings.push(bearingDegrees(polyline[i - 1], polyline[i]));
    }
  }
  let turns = 0;
  for (let i = 1; i < bearings.length; i++) {
    const delta = Math.abs(
      ((bearings[i] - bearings[i - 1] + 540) % 360) - 180,
    );
    if (delta > thresholdDegrees) turns += 1;
  }
  return turns;
}

function lineStringWkt(points: readonly GeoCoordinate[]): string {
  // WKT wants "lon lat"!
  return `SRID=4326;LINESTRING(${
    points.map((p) => `${p.longitude} ${p.latitude}`).join(", ")
  })`;
}

function pointWkt(point: GeoCoordinate): string {
  return `SRID=4326;POINT(${point.longitude} ${point.latitude})`;
}

export async function handleValidateCourse(
  payload: ValidateCoursePayload,
  userId: string,
  deps: ValidateCourseDeps,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const malformed = shapeError(payload);
  if (malformed !== null) {
    return { status: 400, body: { error: malformed } };
  }

  const headers = {
    apikey: deps.serviceKey,
    Authorization: `Bearer ${deps.serviceKey}`,
    "Content-Type": "application/json",
  };

  async function rest(path: string, init?: RequestInit): Promise<Response> {
    return await fetch(`${deps.restUrl}${path}`, {
      ...init,
      headers: { ...headers, ...(init?.headers ?? {}) },
    });
  }

  try {
    // 1. Pro entitlement gate (spec §26). The server re-checks on every
    //    Pro-gated operation; the client's word counts for nothing.
    const proResponse = await rest(`/rpc/has_active_pro`, {
      method: "POST",
      body: JSON.stringify({ p_user: userId }),
    });
    if (!proResponse.ok) {
      return { status: 500, body: { error: "entitlement check failed" } };
    }
    if ((await proResponse.json()) !== true) {
      return { status: 403, body: { error: "pro_required" } };
    }

    // 2. Validate with the same contract-pinned rules the client ran.
    const polyline: GeoCoordinate[] = payload.polyline.map((p) => ({
      latitude: p[0],
      longitude: p[1],
    }));
    const checkpoints: Checkpoint[] = payload.checkpoints.map((c) => ({
      sequence: c[0],
      center: { latitude: c[1], longitude: c[2] },
      radiusMeters: c[3],
    }));
    const issues = validateCourse(polyline, checkpoints);
    if (issues.length > 0) {
      return { status: 422, body: { issues } };
    }

    // 3. Derived catalog fields.
    const matcher = CourseMatcher.create(polyline);
    if (matcher === null) {
      // Unreachable: validation guarantees non-degenerate geometry.
      return { status: 422, body: { error: "degenerate course geometry" } };
    }
    const distance = matcher.totalDistanceMeters;
    const turnCount = countTurns(polyline);
    const estimatedDurationSeconds = Math.round(distance / 12);

    // 4. Service-role INSERT: course, then its gates.
    const courseInsert = await rest("/courses", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        name: payload.name,
        description: payload.description ?? null,
        country: payload.country ?? null,
        creator_id: userId,
        distance_meters: distance,
        estimated_duration_seconds: estimatedDurationSeconds,
        difficulty: payload.difficulty ?? 1,
        turn_count: turnCount,
        geometry: lineStringWkt(polyline),
        start_point: pointWkt(polyline[0]),
        finish_point: pointWkt(polyline[polyline.length - 1]),
        visibility: payload.visibility,
        status: "active",
      }),
    });
    if (!courseInsert.ok) {
      const detail = await courseInsert.text();
      return {
        status: 500,
        body: { error: `course insert failed: ${detail}` },
      };
    }
    const courseId = (await courseInsert.json())[0].id as string;

    const checkpointInsert = await rest("/course_checkpoints", {
      method: "POST",
      body: JSON.stringify(
        checkpoints.map((checkpoint) => ({
          course_id: courseId,
          sequence: checkpoint.sequence,
          center: pointWkt(checkpoint.center),
          radius_meters: checkpoint.radiusMeters,
        })),
      ),
    });
    if (!checkpointInsert.ok) {
      const detail = await checkpointInsert.text();
      // Never leave a gate-less course in the catalog.
      await rest(`/courses?id=eq.${courseId}`, { method: "DELETE" });
      return {
        status: 500,
        body: { error: `checkpoint insert failed: ${detail}` },
      };
    }

    return {
      status: 200,
      body: { courseId, distanceMeters: distance, turnCount },
    };
  } catch (error) {
    return { status: 500, body: { error: String(error) } };
  }
}

// Edge-runtime entrypoint (deploys); tests import handleValidateCourse
// directly. The wrapper resolves the CALLER from their JWT, then performs
// all writes with the service role.
if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    const json = (status: number, body: Record<string, unknown>) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
      });

    if (req.method !== "POST") {
      return json(405, { error: "POST only" });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const authorization = req.headers.get("Authorization");
    if (authorization === null) {
      return json(401, { error: "authentication required" });
    }
    const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
        Authorization: authorization,
      },
    });
    if (!userResponse.ok) {
      await userResponse.body?.cancel();
      return json(401, { error: "authentication required" });
    }
    const userId = (await userResponse.json()).id;
    if (typeof userId !== "string") {
      return json(401, { error: "authentication required" });
    }

    const payload = await req.json().catch(() => null);
    if (payload === null) {
      return json(400, { error: "JSON body required" });
    }

    const result = await handleValidateCourse(
      payload as ValidateCoursePayload,
      userId,
      {
        restUrl: `${supabaseUrl}/rest/v1`,
        serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      },
    );
    return json(result.status, result.body);
  });
}
