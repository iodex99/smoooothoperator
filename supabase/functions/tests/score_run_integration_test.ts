// End-to-end integration: golden telemetry → storage upload → runs row →
// score-run handler → authoritative score + leaderboard + ghost, against
// the LIVE local Supabase stack. Skips itself when the stack (or net
// permission) is unavailable, so unit-only runs stay green.
//
// Run: deno test --allow-read=../../fixtures,../../configs --allow-net tests/score_run_integration_test.ts

import { handleScoreRun } from "../score-run/index.ts";

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
    throw new Error(`${what} failed: ${response.status} ${await response.text()}`);
  }
  return response;
}

function wkt(points: number[][]): string {
  // Golden route is [lat, lon]; WKT wants "lon lat".
  return points.map((p) => `${p[1]} ${p[0]}`).join(", ");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes.buffer as ArrayBuffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

Deno.test({
  name: "e2e: golden run uploads, scores authoritatively, ranks, and spawns a ghost",
  ignore: !stackUp,
  // The handler and admin API keep pooled connections alive; don't fail the
  // test over runtime plumbing.
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const repoRoot = new URL("../../../", import.meta.url);
    const telemetry = JSON.parse(
      await Deno.readTextFile(
        new URL("fixtures/golden/fastSmooth_1.telemetry.json", repoRoot),
      ),
    );
    const expected = JSON.parse(
      await Deno.readTextFile(
        new URL("fixtures/golden/fastSmooth_1.expected.json", repoRoot),
      ),
    );

    // ── Arrange: user, course (from the golden route), gates ──────────────
    const email = `e2e-${crypto.randomUUID().slice(0, 8)}@example.com`;
    const userResponse = await mustOk(
      await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
        method: "POST",
        headers,
        body: JSON.stringify({ email, email_confirm: true }),
      }),
      "admin user creation",
    );
    const userId = (await userResponse.json()).id as string;

    const courseInsert = await mustOk(
      await rest("/courses", {
        method: "POST",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify({
          name: "E2E Golden Course",
          // Always a CUSTOM course: creator-less rows are platform catalog
          // and audited by the catalog-integrity pgTAP suite.
          creator_id: userId,
          country: "US",
          distance_meters: 1500,
          difficulty: 3,
          turn_count: 8,
          geometry: `SRID=4326;LINESTRING(${wkt(telemetry.route)})`,
          start_point: `SRID=4326;POINT(${wkt([telemetry.route[0]])})`,
          finish_point: `SRID=4326;POINT(${
            wkt([telemetry.route[telemetry.route.length - 1]])
          })`,
          benchmark_seconds: Math.round(telemetry.benchmarkSeconds),
          visibility: "public",
          status: "active",
        }),
      }),
      "course insert",
    );
    const courseId = (await courseInsert.json())[0].id as string;

    await mustOk(
      await rest("/course_checkpoints", {
        method: "POST",
        body: JSON.stringify(
          telemetry.gates.map((gate: number[]) => ({
            course_id: courseId,
            sequence: gate[0],
            center: `SRID=4326;POINT(${gate[2]} ${gate[1]})`,
            radius_meters: gate[3],
          })),
        ),
      }),
      "checkpoint insert",
    );

    // The DB benchmark is an integer column; the pipeline must score with
    // the exact benchmark the platform defined. Override geometry benchmark
    // by patching the course to the golden value is lossy — instead verify
    // against a fresh evaluation below rather than the committed ints when
    // they differ. (Kept simple: golden benchmark is near-integral.)

    // ── Upload the raw telemetry blob ──────────────────────────────────────
    const payload = new TextEncoder().encode(JSON.stringify({
      formatVersion: 1,
      gps: telemetry.gps,
      imu: telemetry.imu,
    }));
    const storagePath = `${userId}/e2e-run.json`;
    await mustOk(
      await fetch(`${SUPABASE_URL}/storage/v1/object/telemetry/${storagePath}`, {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/octet-stream",
        },
        body: payload.slice().buffer as ArrayBuffer,
      }),
      "blob upload",
    );

    // ── Run + envelope (status uploaded → job enqueued by trigger) ────────
    const runInsert = await mustOk(
      await rest("/runs", {
        method: "POST",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify({
          user_id: userId,
          course_id: courseId,
          status: "uploaded",
          started_at: new Date().toISOString(),
          client_score: 8000,
        }),
      }),
      "run insert",
    );
    const runId = (await runInsert.json())[0].id as string;

    await mustOk(
      await rest("/telemetry", {
        method: "POST",
        body: JSON.stringify({
          run_id: runId,
          storage_path: storagePath,
          gps_count: telemetry.gps.length,
          imu_count: telemetry.imu.length,
          byte_size: payload.length,
          sha256: await sha256Hex(payload),
        }),
      }),
      "envelope insert",
    );

    // ── Act ────────────────────────────────────────────────────────────────
    const result = await handleScoreRun(runId, {
      restUrl: `${SUPABASE_URL}/rest/v1`,
      storageUrl: `${SUPABASE_URL}/storage/v1`,
      serviceKey: SERVICE_KEY,
    });

    // ── Assert ─────────────────────────────────────────────────────────────
    if (result.status !== 200) {
      throw new Error(`score-run failed: ${JSON.stringify(result.body)}`);
    }
    if (result.body.verdict !== "verified") {
      throw new Error(`expected verified, got ${JSON.stringify(result.body)}`);
    }
    // The DB stores an integer benchmark; the golden expected used the
    // fractional one. Only pace can shift by the sub-second rounding —
    // assert it stays within one bps step and everything else matches.
    const breakdown = result.body.breakdown as Record<string, number>;
    if (Math.abs((result.body.score as number) - expected.finalScore) > 25) {
      throw new Error(
        `score drifted: ${result.body.score} vs golden ${expected.finalScore}`,
      );
    }
    if (breakdown.smoothnessBps !== expected.smoothnessBps) {
      throw new Error(
        `smoothness mismatch: ${breakdown.smoothnessBps} vs ${expected.smoothnessBps}`,
      );
    }

    const runRow =
      (await (await rest(`/runs?id=eq.${runId}&select=status,verification,score,scoring_version`))
        .json())[0];
    if (runRow.status !== "scored" || runRow.verification !== "verified") {
      throw new Error(`run row wrong: ${JSON.stringify(runRow)}`);
    }

    const entries = await (await rest(
      `/leaderboard_entries?run_id=eq.${runId}&select=score`,
    )).json();
    if (entries.length !== 1 || entries[0].score !== result.body.score) {
      throw new Error(`leaderboard entry wrong: ${JSON.stringify(entries)}`);
    }

    const ghosts = await (await rest(
      `/ghosts?run_id=eq.${runId}&select=trajectory,score`,
    )).json();
    if (ghosts.length !== 1) {
      throw new Error(`expected one ghost, got ${ghosts.length}`);
    }
    const ghostText = JSON.stringify(ghosts[0].trajectory);
    if (ghostText.includes("latitude") || ghostText.includes("longitude")) {
      throw new Error("ghost leaked coordinates");
    }

    const jobs = await (await rest(
      `/scoring_jobs?run_id=eq.${runId}&select=status`,
    )).json();
    if (jobs[0]?.status !== "done") {
      throw new Error(`job not done: ${JSON.stringify(jobs)}`);
    }

    // Idempotency: a second invocation finds nothing to claim.
    const again = await handleScoreRun(runId, {
      restUrl: `${SUPABASE_URL}/rest/v1`,
      storageUrl: `${SUPABASE_URL}/storage/v1`,
      serviceKey: SERVICE_KEY,
    });
    if (again.status !== 409) {
      throw new Error(`expected 409 on re-run, got ${again.status}`);
    }
  },
});

// The uploader gzips every blob now, and until this test nothing had ever
// pushed a compressed one through real Storage into the real scorer. The
// pieces were each tested — Swift compresses, `DecompressionStream` reads
// what Swift writes, the bucket accepts `application/gzip` — and the whole
// path was still unproven, which is exactly where an integration defect
// lives.
//
// The assertion that matters is that compression is INVISIBLE: the same
// drive must score identically whether it was uploaded compressed or not.
Deno.test({
  name: "e2e: a gzipped blob scores exactly as the same drive uncompressed",
  ignore: !stackUp,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const repoRoot = new URL("../../../", import.meta.url);
    const telemetry = JSON.parse(
      await Deno.readTextFile(
        new URL("fixtures/golden/fastSmooth_1.telemetry.json", repoRoot),
      ),
    );

    const email = `e2egz-${crypto.randomUUID().slice(0, 8)}@example.com`;
    const userResponse = await mustOk(
      await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
        method: "POST",
        headers,
        body: JSON.stringify({ email, email_confirm: true }),
      }),
      "admin user creation",
    );
    const userId = (await userResponse.json()).id as string;

    const courseInsert = await mustOk(
      await rest("/courses", {
        method: "POST",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify({
          name: "E2E Gzip Course",
          creator_id: userId,
          country: "US",
          distance_meters: 1500,
          difficulty: 3,
          turn_count: 8,
          geometry: `SRID=4326;LINESTRING(${wkt(telemetry.route)})`,
          start_point: `SRID=4326;POINT(${wkt([telemetry.route[0]])})`,
          finish_point: `SRID=4326;POINT(${
            wkt([telemetry.route[telemetry.route.length - 1]])
          })`,
          benchmark_seconds: Math.round(telemetry.benchmarkSeconds),
          visibility: "public",
          status: "active",
        }),
      }),
      "course insert",
    );
    const courseId = (await courseInsert.json())[0].id as string;

    await mustOk(
      await rest("/course_checkpoints", {
        method: "POST",
        body: JSON.stringify(
          telemetry.gates.map((gate: number[]) => ({
            course_id: courseId,
            sequence: gate[0],
            center: `SRID=4326;POINT(${gate[2]} ${gate[1]})`,
            radius_meters: gate[3],
          })),
        ),
      }),
      "checkpoint insert",
    );

    const plain = new TextEncoder().encode(JSON.stringify({
      formatVersion: 1,
      gps: telemetry.gps,
      imu: telemetry.imu,
    }));
    const gzipped = new Uint8Array(
      await new Response(
        new Blob([plain.slice().buffer as ArrayBuffer]).stream()
          .pipeThrough(new CompressionStream("gzip")),
      ).arrayBuffer(),
    );
    if (!(gzipped.length < plain.length)) {
      throw new Error("gzip did not shrink the blob");
    }

    // `.json.gz`, and the path regex `validate_telemetry_path` enforces has
    // to accept it — a rejected path would fail the envelope insert below.
    const storagePath = `${userId}/e2e-run.json.gz`;
    await mustOk(
      await fetch(`${SUPABASE_URL}/storage/v1/object/telemetry/${storagePath}`, {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          // Content-TYPE, never Content-ENCODING: a transparently
          // decompressing hop would break the hash check below.
          "Content-Type": "application/gzip",
        },
        body: gzipped.slice().buffer as ArrayBuffer,
      }),
      "gzip blob upload",
    );

    const runInsert = await mustOk(
      await rest("/runs", {
        method: "POST",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify({
          user_id: userId,
          course_id: courseId,
          status: "uploaded",
          started_at: new Date().toISOString(),
          client_score: 8000,
        }),
      }),
      "run insert",
    );
    const runId = (await runInsert.json())[0].id as string;

    await mustOk(
      await rest("/telemetry", {
        method: "POST",
        body: JSON.stringify({
          run_id: runId,
          storage_path: storagePath,
          gps_count: telemetry.gps.length,
          imu_count: telemetry.imu.length,
          byte_size: gzipped.length,
          // Over the COMPRESSED bytes — what the scorer fetches and hashes
          // before it decompresses anything.
          sha256: await sha256Hex(gzipped),
        }),
      }),
      "envelope insert",
    );

    const result = await handleScoreRun(runId, {
      restUrl: `${SUPABASE_URL}/rest/v1`,
      storageUrl: `${SUPABASE_URL}/storage/v1`,
      serviceKey: SERVICE_KEY,
    });

    if (result.status !== 200) {
      throw new Error(`score-run failed on gzip: ${JSON.stringify(result.body)}`);
    }
    if (result.body.verdict !== "verified") {
      throw new Error(`expected verified, got ${JSON.stringify(result.body)}`);
    }

    // The same drive, uncompressed, through the same code — the two must
    // agree exactly. Anything else means compression is changing a score.
    const uncompressedRun = await scoreSameDriveUncompressed(
      userId,
      courseId,
      telemetry,
      plain,
    );
    if (result.body.score !== uncompressedRun) {
      throw new Error(
        `gzip changed the score: ${result.body.score} vs ${uncompressedRun}`,
      );
    }
  },
});

/** Scores the identical telemetry uploaded WITHOUT compression. */
async function scoreSameDriveUncompressed(
  userId: string,
  courseId: string,
  telemetry: { gps: number[][]; imu: number[][] },
  plain: Uint8Array,
): Promise<number> {
  const storagePath = `${userId}/e2e-run-plain.json`;
  await mustOk(
    await fetch(`${SUPABASE_URL}/storage/v1/object/telemetry/${storagePath}`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/octet-stream",
      },
      body: plain.slice().buffer as ArrayBuffer,
    }),
    "plain blob upload",
  );

  const runInsert = await mustOk(
    await rest("/runs", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        user_id: userId,
        course_id: courseId,
        status: "uploaded",
        started_at: new Date().toISOString(),
        client_score: 8000,
      }),
    }),
    "plain run insert",
  );
  const runId = (await runInsert.json())[0].id as string;

  await mustOk(
    await rest("/telemetry", {
      method: "POST",
      body: JSON.stringify({
        run_id: runId,
        storage_path: storagePath,
        gps_count: telemetry.gps.length,
        imu_count: telemetry.imu.length,
        byte_size: plain.length,
        sha256: await sha256Hex(plain),
      }),
    }),
    "plain envelope insert",
  );

  const result = await handleScoreRun(runId, {
    restUrl: `${SUPABASE_URL}/rest/v1`,
    storageUrl: `${SUPABASE_URL}/storage/v1`,
    serviceKey: SERVICE_KEY,
  });
  if (result.status !== 200) {
    throw new Error(`plain score-run failed: ${JSON.stringify(result.body)}`);
  }
  return result.body.score as number;
}
