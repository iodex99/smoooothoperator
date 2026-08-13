// Today's Challenge integration: the full selection flow against the LIVE
// local Supabase stack — radius ladder, rotation, friend boost, caching,
// low-density and empty-area fallbacks, and the honesty rules. Skips itself
// when the stack (or net permission) is unavailable.
//
// Fixtures live in the Sahara (~25N 10E) — far from every seeded catalog
// course, so counts and winners are deterministic.
//
// Run: deno test --allow-read=../../fixtures,../../configs --allow-net tests/today_challenge_integration_test.ts

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { handleTodayChallenge } from "../today-challenge/index.ts";

const SUPABASE_URL = "http://127.0.0.1:54321";
const SERVICE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

const netAllowed =
  (await Deno.permissions.query({ name: "net" })).state === "granted";
let stackUp = false;
if (netAllowed) {
  try {
    const probe = await fetch(`${SUPABASE_URL}/rest/v1/`, { headers });
    await probe.body?.cancel();
    stackUp = probe.status < 500;
  } catch {
    stackUp = false;
  }
}

const deps = { restUrl: `${SUPABASE_URL}/rest/v1`, serviceKey: SERVICE_KEY };

async function rest(path: string, init?: RequestInit): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    ...init,
    headers: { ...headers, ...(init?.headers ?? {}) },
  });
}

async function mustOk(response: Response, what: string): Promise<Response> {
  if (!response.ok) {
    throw new Error(`${what} failed: ${response.status} ${await response.text()}`);
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

/** Inserts a minimal valid PUBLIC CUSTOM course near (lat, lon) — always
 * with a creator, so fixtures never masquerade as platform-catalog rows
 * (the catalog integrity pgTAP suite audits creator-less courses). */
async function createCourse(
  name: string,
  lat: number,
  lon: number,
  creatorId: string,
  extras: Record<string, unknown> = {},
): Promise<string> {
  const finishLat = lat + 0.02;
  const response = await mustOk(
    await rest("/courses", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        name,
        creator_id: creatorId,
        distance_meters: 6000,
        difficulty: 3,
        turn_count: 10,
        benchmark_seconds: 480,
        geometry: `LINESTRING(${lon} ${lat}, ${lon} ${finishLat})`,
        start_point: `POINT(${lon} ${lat})`,
        finish_point: `POINT(${lon} ${finishLat})`,
        visibility: "public",
        status: "active",
        ...extras,
      }),
    }),
    `create course ${name}`,
  );
  return ((await response.json()) as { id: string }[])[0].id;
}

/** A scored run yesterday for (user, course); returns run id. */
async function createRun(userId: string, courseId: string): Promise<string> {
  const response = await mustOk(
    await rest("/runs", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        user_id: userId,
        course_id: courseId,
        status: "scored",
        verification: "verified",
        started_at: new Date(Date.now() - 86_400_000).toISOString(),
        duration_seconds: 500,
      }),
    }),
    "create run",
  );
  return ((await response.json()) as { id: string }[])[0].id;
}

async function clearAssignments(userId: string): Promise<void> {
  await mustOk(
    await rest(`/challenge_assignments?user_id=eq.${userId}`, { method: "DELETE" }),
    "clear assignments",
  );
}

Deno.test({
  name:
    "e2e: today-challenge — ladder, rotation, friends, caching, honesty, fallbacks",
  ignore: !stackUp,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    // ── Fixtures ──────────────────────────────────────────────────────────
    // Every run claims a fresh random zone in a vast empty band (mid-
    // Pacific) so reruns and aborted runs can never pollute each other; the
    // zones sit 300+ km apart within a run.
    const baseLat = -35 + Math.random() * 14;
    const baseLon = -135 + Math.random() * 28;
    const CLUSTER = { lat: baseLat, lon: baseLon }; // 4 public courses within 7 km
    const SINGLE = { lat: baseLat + 3, lon: baseLon }; // exactly 1 course, 4 km away
    const SPARSE = { lat: baseLat - 3, lon: baseLon }; // nearest course ~40 km away
    const EMPTY = { lat: 5.0, lon: -30.0 }; // mid-Atlantic: nothing, ever

    const alpha = await createUser("tc-alpha");
    const bravo = await createUser("tc-bravo");
    const charlie = await createUser("tc-charlie");
    const solo = await createUser("tc-solo");

    const tag = crypto.randomUUID().slice(0, 8);
    const clusterCourses = [
      await createCourse(`TCI ${tag} A`, CLUSTER.lat + 0.010, CLUSTER.lon, bravo),
      await createCourse(`TCI ${tag} B`, CLUSTER.lat + 0.030, CLUSTER.lon, bravo),
      await createCourse(`TCI ${tag} C`, CLUSTER.lat - 0.030, CLUSTER.lon, bravo),
      await createCourse(`TCI ${tag} D`, CLUSTER.lat, CLUSTER.lon + 0.050, bravo),
    ];
    const singleCourse = await createCourse(
      `TCI ${tag} Solo`, SINGLE.lat + 0.035, SINGLE.lon, bravo,
    );
    await createCourse(`TCI ${tag} Sparse`, SPARSE.lat + 0.36, SPARSE.lon, bravo); // ~40 km

    const base = {
      latitude: CLUSTER.lat,
      longitude: CLUSTER.lon,
      timezone: "Africa/Algiers",
      debug: true,
    };

    // 1. Many nearby courses → ready at the smallest radius, honest zeros.
    const first = await handleTodayChallenge({ userId: alpha, ...base }, deps);
    assertEquals(first.state, "ready");
    const firstCourse = (first.course as { id: string }).id;
    assert(clusterCourses.includes(firstCourse), "winner comes from the cluster");
    assertEquals(first.radiusKm, 10);
    assertEquals(first.participantsToday, 0, "no fake participants");
    assertEquals(first.firstRecord, true, "set-the-first-record state");
    assertEquals((first.format as { key: string }).key, "SMOOTH_SPRINT");
    const polyline = (first.course as { polyline: number[][] }).polyline;
    assert(polyline.length >= 2, "drive-ready polyline included");

    // 2. Second call the same day → cache hit, same course.
    const again = await handleTodayChallenge({ userId: alpha, ...base }, deps);
    assertEquals((again.course as { id: string }).id, firstCourse);
    assertEquals((again.debug as { cache: string }).cache, "hit");

    // 3. Rotation: alpha drove the winner "yesterday" → reselect avoids it.
    await createRun(alpha, firstCourse);
    await clearAssignments(alpha);
    const rotated = await handleTodayChallenge({ userId: alpha, ...base }, deps);
    assertEquals(rotated.state, "ready");
    assertNotEquals(
      (rotated.course as { id: string }).id,
      firstCourse,
      "yesterday's course rotates out when alternatives exist",
    );

    // 4. Friend activity: bravo set a score on course D; charlie (friend of
    //    bravo, no history) should be pulled toward D and see the bait.
    const courseD = clusterCourses[3];
    const bravoRun = await createRun(bravo, courseD);
    await mustOk(
      await rest("/leaderboard_entries", {
        method: "POST",
        body: JSON.stringify({
          course_id: courseD,
          user_id: bravo,
          run_id: bravoRun,
          score: 9100,
          duration_seconds: 500,
        }),
      }),
      "friend leaderboard entry",
    );
    await mustOk(
      await rest("/friendships", {
        method: "POST",
        body: JSON.stringify({
          requester_id: charlie,
          addressee_id: bravo,
          status: "accepted",
        }),
      }),
      "friendship",
    );
    const friendly = await handleTodayChallenge({ userId: charlie, ...base }, deps);
    assertEquals(friendly.state, "ready");
    assertEquals((friendly.course as { id: string }).id, courseD);
    const friendBest = friendly.friendBest as { score: number; username: string };
    assertEquals(friendBest.score, 9100, "friend best shown honestly");
    assertEquals(friendly.firstRecord, false);

    // 5. Single-course area: the only course wins even after driving it.
    await createRun(solo, singleCourse);
    const soloResult = await handleTodayChallenge(
      { userId: solo, latitude: SINGLE.lat, longitude: SINGLE.lon, timezone: "Africa/Algiers" },
      deps,
    );
    assertEquals(soloResult.state, "ready");
    assertEquals((soloResult.course as { id: string }).id, singleCourse);

    // 6. Sparse area: ladder expands past 10/25 km and reports the radius.
    await clearAssignments(solo);
    const sparse = await handleTodayChallenge(
      {
        userId: solo,
        latitude: SPARSE.lat,
        longitude: SPARSE.lon,
        timezone: "Africa/Algiers",
        debug: true,
      },
      deps,
    );
    assertEquals(sparse.state, "ready");
    assertEquals(sparse.radiusKm, 50);

    // 7. Empty area: graceful coming-soon, nothing fabricated.
    await clearAssignments(solo);
    const empty = await handleTodayChallenge(
      { userId: solo, latitude: EMPTY.lat, longitude: EMPTY.lon, timezone: "Etc/UTC" },
      deps,
    );
    assertEquals(empty.state, "coming-soon");
    assertEquals(empty.course, undefined);

    // 8. No location, no cache → honest unavailable state.
    await clearAssignments(charlie);
    const located = await handleTodayChallenge(
      { userId: charlie, timezone: "Europe/London" },
      deps,
    );
    assertEquals(located.state, "unavailable");

    // 9. Local-date isolation: assignments key on the user's LOCAL date.
    const nowLA = new Date("2026-08-13T00:30:00Z");
    await clearAssignments(alpha);
    const laDate = await handleTodayChallenge(
      { userId: alpha, ...base, timezone: "America/Los_Angeles" },
      { ...deps, now: nowLA },
    );
    assertEquals(laDate.localDate, "2026-08-12");
    const londonDate = await handleTodayChallenge(
      { userId: alpha, ...base, timezone: "Europe/London" },
      { ...deps, now: nowLA },
    );
    assertEquals(londonDate.localDate, "2026-08-13");
  },
});
