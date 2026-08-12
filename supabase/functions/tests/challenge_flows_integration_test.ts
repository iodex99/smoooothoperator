// Challenge flows integration: Pro-gated course creation (validate-course,
// L8) and anonymous invite-code resolution (resolve-challenge, L9), against
// the LIVE local Supabase stack. Skips itself when the stack (or net
// permission) is unavailable, so unit-only runs stay green.
//
// Run: deno test --allow-read=../../fixtures,../../configs --allow-net tests/challenge_flows_integration_test.ts

import {
  handleValidateCourse,
  type ValidateCoursePayload,
} from "../validate-course/index.ts";
import { handleResolveChallenge } from "../resolve-challenge/index.ts";
import { destination, type GeoCoordinate } from "../_shared/pipeline/geo.ts";

// Standard supabase local development credentials (identical on every
// machine; secrets never live in this repo).
const SUPABASE_URL = "http://127.0.0.1:54321";
const SERVICE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

const netAllowed =
  (await Deno.permissions.query({ name: "net" })).state === "granted";
let stackUp = false;
if (netAllowed) {
  try {
    const probe = await fetch(`${SUPABASE_URL}/rest/v1/`, {
      headers: { apikey: SERVICE_KEY },
    });
    await probe.body?.cancel();
    stackUp = probe.status < 500;
  } catch {
    stackUp = false;
  }
}

const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

async function rest(path: string, init?: RequestInit): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    ...init,
    headers: { ...headers, ...(init?.headers ?? {}) },
  });
}

async function mustOk(response: Response, what: string): Promise<Response> {
  if (!response.ok) {
    throw new Error(
      `${what} failed: ${response.status} ${await response.text()}`,
    );
  }
  return response;
}

async function createUser(label: string): Promise<string> {
  const email = `${label}-${crypto.randomUUID().slice(0, 8)}@example.com`;
  const response = await mustOk(
    await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: "POST",
      headers,
      body: JSON.stringify({ email, email_confirm: true }),
    }),
    "admin user creation",
  );
  return (await response.json()).id as string;
}

/** A straight route heading due north from Malibu: one point every 100 m. */
function straightPolyline(lengthMeters: number): [number, number][] {
  const start: GeoCoordinate = { latitude: 34.0259, longitude: -118.7798 };
  const points: [number, number][] = [];
  for (let meters = 0; meters <= lengthMeters; meters += 100) {
    const point = destination(start, 0, meters);
    points.push([point.latitude, point.longitude]);
  }
  return points;
}

/** Start/mid/finish gates (or start/finish only for sub-km routes). */
function coursePayload(
  name: string,
  lengthMeters: number,
): ValidateCoursePayload {
  const polyline = straightPolyline(lengthMeters);
  const start = polyline[0];
  const mid = polyline[Math.floor((polyline.length - 1) / 2)];
  const finish = polyline[polyline.length - 1];
  const checkpoints: [number, number, number, number][] = lengthMeters >= 1_000
    ? [
      [0, start[0], start[1], 30],
      [1, mid[0], mid[1], 30],
      [2, finish[0], finish[1], 30],
    ]
    : [
      [0, start[0], start[1], 30],
      [1, finish[0], finish[1], 30],
    ];
  return {
    name,
    country: "US",
    visibility: "public",
    polyline,
    checkpoints,
    difficulty: 2,
  };
}

Deno.test({
  name:
    "e2e: pro gate refuses, validation rejects, a valid course publishes, and its challenge resolves anonymously",
  ignore: !stackUp,
  // The handlers and admin API keep pooled connections alive; don't fail
  // the test over runtime plumbing.
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const deps = {
      restUrl: `${SUPABASE_URL}/rest/v1`,
      serviceKey: SERVICE_KEY,
    };

    // ── Arrange: A holds an active Pro subscription, B holds nothing ─────
    const userA = await createUser("challenge-pro");
    const userB = await createUser("challenge-free");
    await mustOk(
      await rest("/subscriptions", {
        method: "POST",
        body: JSON.stringify({
          user_id: userA,
          product_id: "smooooth.pro.monthly",
          original_transaction_id: `e2e-${crypto.randomUUID()}`,
          latest_transaction_id: `e2e-${crypto.randomUUID()}`,
          status: "active",
          expires_at: new Date(Date.now() + 86_400_000).toISOString(),
          environment: "sandbox",
        }),
      }),
      "subscription insert",
    );

    // ── Non-Pro creators are refused before anything else (spec §26) ─────
    const refused = await handleValidateCourse(
      coursePayload("Free User Course", 3_000),
      userB,
      deps,
    );
    if (refused.status !== 403 || refused.body.error !== "pro_required") {
      throw new Error(
        `expected 403 pro_required, got ${refused.status} ${
          JSON.stringify(refused.body)
        }`,
      );
    }

    // ── Invalid geometry (500 m) is rejected with issues ─────────────────
    const rejected = await handleValidateCourse(
      coursePayload("Too Short Course", 500),
      userA,
      deps,
    );
    if (rejected.status !== 422) {
      throw new Error(
        `expected 422, got ${rejected.status} ${JSON.stringify(rejected.body)}`,
      );
    }
    const kinds = (rejected.body.issues as { kind: string }[]).map(
      (issue) => issue.kind,
    );
    if (!kinds.includes("tooShort")) {
      throw new Error(`expected a tooShort issue, got [${kinds.join(", ")}]`);
    }

    // ── A valid 3 km course publishes ─────────────────────────────────────
    const courseName = `E2E Challenge Course ${
      crypto.randomUUID().slice(0, 8)
    }`;
    const created = await handleValidateCourse(
      coursePayload(courseName, 3_000),
      userA,
      deps,
    );
    if (created.status !== 200) {
      throw new Error(
        `validate-course failed: ${created.status} ${
          JSON.stringify(created.body)
        }`,
      );
    }
    const courseId = created.body.courseId as string;
    const distance = created.body.distanceMeters as number;
    if (Math.abs(distance - 3_000) > 10) {
      throw new Error(`distance drifted: ${distance} vs ~3000`);
    }
    if (created.body.turnCount !== 0) {
      throw new Error(
        `a straight line has no turns, got ${created.body.turnCount}`,
      );
    }

    const courseRow = (await (await rest(
      `/courses?id=eq.${courseId}&select=creator_id,status,visibility`,
    )).json())[0];
    if (courseRow?.creator_id !== userA) {
      throw new Error(`course row wrong: ${JSON.stringify(courseRow)}`);
    }
    const gateRows = await (await rest(
      `/course_checkpoints?course_id=eq.${courseId}&select=sequence`,
    )).json();
    if (!Array.isArray(gateRows) || gateRows.length !== 3) {
      throw new Error(
        `expected 3 checkpoints, got ${JSON.stringify(gateRows)}`,
      );
    }

    // ── Challenge + anonymous share-link resolution (spec §79) ───────────
    const challengeInsert = await mustOk(
      await rest("/challenges", {
        method: "POST",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify({
          course_id: courseId,
          creator_id: userA,
          type: "friend",
          name: "E2E Friend Challenge",
        }),
      }),
      "challenge insert",
    );
    const inviteCode = (await challengeInsert.json())[0]
      .invite_code as string;

    const resolved = await handleResolveChallenge(inviteCode, deps);
    if (resolved.status !== 200) {
      throw new Error(
        `resolve failed: ${resolved.status} ${JSON.stringify(resolved.body)}`,
      );
    }
    const body = resolved.body as {
      course: { name: string };
      creator: { username: string };
      participantCount: number;
      creatorBestScore: number | null;
    };
    if (body.course.name !== courseName) {
      throw new Error(`course name wrong: ${JSON.stringify(body.course)}`);
    }
    const profileA = (await (await rest(
      `/profiles?id=eq.${userA}&select=username`,
    )).json())[0];
    if (body.creator.username !== profileA.username) {
      throw new Error(`creator wrong: ${JSON.stringify(body.creator)}`);
    }
    if (body.participantCount !== 0) {
      throw new Error(
        `expected participantCount 0, got ${body.participantCount}`,
      );
    }
    if (body.creatorBestScore !== null) {
      throw new Error(
        `creator has no runs; best score must be null, got ${body.creatorBestScore}`,
      );
    }

    // The response is the security boundary: no geometry, no checkpoint
    // coordinates, no telemetry — anywhere in the JSON.
    const text = JSON.stringify(resolved.body);
    for (const banned of ["geometry", "polyline", "latitude"]) {
      if (text.includes(banned)) {
        throw new Error(`resolve-challenge leaked '${banned}': ${text}`);
      }
    }

    // Unknown but well-formed code → 404. 'ZZZZZZZZZZ' can never be issued
    // (codes are uppercase hex), so the format gate rejects it as 400,
    // exactly like the outright-malformed 'abc'.
    const unknown = await handleResolveChallenge("ABCDEF1234", deps);
    if (unknown.status !== 404) {
      throw new Error(`expected 404 for unknown code, got ${unknown.status}`);
    }
    const nonHex = await handleResolveChallenge("ZZZZZZZZZZ", deps);
    if (nonHex.status !== 400) {
      throw new Error(`expected 400 for non-hex code, got ${nonHex.status}`);
    }
    const malformed = await handleResolveChallenge("abc", deps);
    if (malformed.status !== 400) {
      throw new Error(
        `expected 400 for malformed code, got ${malformed.status}`,
      );
    }
  },
});
