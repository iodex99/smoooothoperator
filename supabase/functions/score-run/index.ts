// score-run — the authoritative scoring path (spec §46).
//
// Flow: claim the run's scoring job (SKIP-LOCKED semantics via a guarded
// UPDATE) → load course geometry + telemetry envelope → download the raw
// blob → verify its hash → run the SAME evaluation pipeline the client ran
// (cross-validated against the Swift reference by xval) → apply everything
// atomically through the apply_run_result RPC.
//
// The handler core is exported so integration tests can drive it against a
// local stack without the edge runtime; Deno.serve wires it for deploys.

import { evaluate } from "../_shared/pipeline/pipeline.ts";
import { buildGoldenExpected } from "../_shared/pipeline/golden.ts";
import type {
  Checkpoint,
  GPSSample,
  IMUSample,
} from "../_shared/pipeline/types.ts";
import { trajectoryDuration } from "../_shared/pipeline/types.ts";
import type { GeoCoordinate } from "../_shared/pipeline/geo.ts";
import { parseScoringConfig } from "../_shared/pipeline/scoring.ts";
import { generateGhost } from "../_shared/pipeline/ghost.ts";
import {
  FREE_RUNS_PER_DAY,
  utcDayStart,
  withinAllowance,
} from "../_shared/allowance.ts";

export interface ScoreRunOptions {
  /** Authenticated caller. When present the run must belong to them; when
   * absent the caller is trusted internal machinery (the stale-job sweeper).
   * Never derive this from the request body. */
  callerId?: string;
}

export interface ScoreRunDeps {
  /** PostgREST base URL, e.g. http://127.0.0.1:54321/rest/v1 */
  restUrl: string;
  /** Storage base URL, e.g. http://127.0.0.1:54321/storage/v1 */
  storageUrl: string;
  serviceKey: string;
  /** Raw JSON of the active scoring config (from the scoring_configs table). */
  scoringConfigJson?: string;
}

interface UploadedTelemetry {
  formatVersion: number;
  gps: number[][];
  imu: number[][];
}

const ABSENT = -9999;

function parseUpload(json: UploadedTelemetry): {
  gps: GPSSample[];
  imu: IMUSample[];
} {
  const gps: GPSSample[] = json.gps.map((row) => ({
    timestamp: row[0],
    coordinate: { latitude: row[1], longitude: row[2] },
    horizontalAccuracy: row[3],
    course: row[4] === ABSENT ? null : row[4],
    speed: row[5] === ABSENT ? null : row[5],
    altitude: row[6] === ABSENT ? null : row[6],
  }));
  const imu: IMUSample[] = json.imu.map((row) => ({
    timestamp: row[0],
    accelX: row[1],
    accelY: row[2],
    accelZ: row[3],
    gyroX: row[4],
    gyroY: row[5],
    gyroZ: row[6],
  }));
  return { gps, imu };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    bytes.buffer as ArrayBuffer,
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function handleScoreRun(
  runId: string,
  deps: ScoreRunDeps,
  options?: ScoreRunOptions,
): Promise<{ status: number; body: Record<string, unknown> }> {
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

  async function failJob(message: string): Promise<void> {
    await rest(`/scoring_jobs?run_id=eq.${runId}`, {
      method: "PATCH",
      body: JSON.stringify({ status: "failed", last_error: message }),
    });
  }

  // 1. Claim the job (guarded update = skip-locked semantics over REST).
  const claim = await rest(
    `/scoring_jobs?run_id=eq.${runId}&status=in.(pending,failed)`,
    {
      method: "PATCH",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({ status: "processing" }),
    },
  );
  const claimed = claim.ok ? await claim.json() : [];
  if (!Array.isArray(claimed) || claimed.length === 0) {
    return {
      status: 409,
      body: { error: "no claimable scoring job for this run" },
    };
  }

  try {
    // 2. Run + envelope + course geometry.
    const runResponse = await rest(
      `/runs?id=eq.${runId}&select=id,user_id,course_id,status`,
    );
    const runs = await runResponse.json();
    if (!Array.isArray(runs) || runs.length === 0) {
      await failJob("run not found");
      return { status: 404, body: { error: "run not found" } };
    }
    const run = runs[0];

    // Ownership. Without this any authenticated user could submit someone
    // else's runId and receive their score, confidence and anti-cheat
    // integrity flags in the response body.
    if (options?.callerId !== undefined && run.user_id !== options.callerId) {
      return { status: 404, body: { error: "run not found" } };
    }

    // Free-tier ceiling, enforced where it cannot be edited away. The client
    // stops you starting a fourth run; this stops a modified client from
    // RANKING one. The run itself is kept — the drive happened — it simply
    // isn't scored until the allowance resets or the user upgrades.
    const proResponse = await rest(`/rpc/has_active_pro`, {
      method: "POST",
      body: JSON.stringify({ p_user: run.user_id }),
    });
    const isPro = proResponse.ok ? await proResponse.json() === true : false;
    if (!isPro) {
      // Keyed on `verification`, NOT `status`: status is client-writable
      // within its allowed transition, so counting it let an attacker flip
      // scored runs back and reset the meter while keeping their rankings.
      // `verification` has no client grant at all.
      const todayResponse = await rest(
        `/runs?user_id=eq.${run.user_id}&verification=not.is.null` +
          `&created_at=gte.${utcDayStart()}&select=id`,
      );
      const scoredToday = todayResponse.ok
        ? ((await todayResponse.json()) as unknown[]).length
        : 0;
      if (!withinAllowance(scoredToday, isPro)) {
        await failJob("daily allowance reached");
        return {
          status: 402,
          body: {
            error: "daily_allowance_reached",
            freeRunsPerDay: FREE_RUNS_PER_DAY,
          },
        };
      }
    }

    const envelopeResponse = await rest(
      `/telemetry?run_id=eq.${runId}&select=storage_path,sha256`,
    );
    const envelopes = await envelopeResponse.json();
    if (!Array.isArray(envelopes) || envelopes.length === 0) {
      await failJob("telemetry envelope missing");
      return { status: 422, body: { error: "telemetry envelope missing" } };
    }
    const envelope = envelopes[0];

    // The storage path is client-supplied. It is interpolated into a
    // service-role storage URL below, so a traversal payload would read
    // arbitrary objects with RLS bypassed. Uploads are confined to
    // `<user-uuid>/...` by storage policy; require the stored path to match
    // the run's owner and contain no traversal segments.
    const expectedPrefix = `${run.user_id}/`;
    if (
      typeof envelope.storage_path !== "string" ||
      !envelope.storage_path.startsWith(expectedPrefix) ||
      envelope.storage_path.includes("..") ||
      envelope.storage_path.includes("//")
    ) {
      await failJob("telemetry path rejected");
      return { status: 422, body: { error: "telemetry envelope invalid" } };
    }

    const geometryResponse = await rest(`/rpc/course_pipeline_geometry`, {
      method: "POST",
      body: JSON.stringify({ course: run.course_id }),
    });
    const geometry = await geometryResponse.json();
    if (!geometry || !geometry.polyline) {
      await failJob("course geometry unavailable");
      return { status: 422, body: { error: "course geometry unavailable" } };
    }

    // 3. Download the blob and verify its integrity envelope.
    const blobResponse = await fetch(
      `${deps.storageUrl}/object/telemetry/${envelope.storage_path}`,
      { headers },
    );
    if (!blobResponse.ok) {
      await failJob(`blob download failed: ${blobResponse.status}`);
      return { status: 422, body: { error: "telemetry blob unavailable" } };
    }
    let bytes = new Uint8Array(await blobResponse.arrayBuffer());
    const hash = await sha256Hex(bytes);
    if (hash !== envelope.sha256) {
      await failJob("telemetry hash mismatch");
      return { status: 422, body: { error: "telemetry hash mismatch" } };
    }
    // Transparent gzip: uploads may be raw JSON or gzip (magic 1f 8b).
    if (bytes.length > 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
      const stream = new Blob([bytes.slice().buffer]).stream()
        .pipeThrough(new DecompressionStream("gzip"));
      bytes = new Uint8Array(await new Response(stream).arrayBuffer());
    }
    const upload = parseUpload(JSON.parse(new TextDecoder().decode(bytes)));

    // 4. The pipeline — identical to the Swift reference (xval-pinned).
    const scoringConfig = parseScoringConfig(
      JSON.parse(deps.scoringConfigJson ?? await activeConfig(rest)),
    );
    const polyline: GeoCoordinate[] = geometry.polyline.map(
      (p: number[]) => ({ latitude: p[0], longitude: p[1] }),
    );
    const gates: Checkpoint[] = geometry.gates.map((g: number[]) => ({
      sequence: g[0],
      center: { latitude: g[1], longitude: g[2] },
      radiusMeters: g[3],
    }));
    const outcome = evaluate({
      gps: upload.gps,
      imu: upload.imu,
      route: polyline,
      gates,
      benchmarkSeconds: geometry.benchmarkSeconds ?? 0,
      scoringConfig,
    });
    if (outcome === null) {
      await failJob("degenerate course geometry");
      return { status: 422, body: { error: "degenerate course geometry" } };
    }
    const expected = buildGoldenExpected(outcome);

    // 5. Ghost only for verified finished runs (spec §44).
    const finished = outcome.gatesHit === gates.length && gates.length > 0;
    const ghost = expected.verdict === "verified" && finished
      ? generateGhost(outcome.trajectory, polyline, gates)
      : null;

    const apply = await rest(`/rpc/apply_run_result`, {
      method: "POST",
      body: JSON.stringify({
        p_run_id: runId,
        p_verification: expected.verdict,
        p_score: expected.finalScore,
        p_pace_bps: expected.paceBps,
        p_smoothness_bps: expected.smoothnessBps,
        p_control_bps: expected.controlBps,
        p_compliance_bps: expected.complianceBps,
        p_confidence: expected.confidenceScore,
        p_scoring_version: expected.scoringVersion,
        p_integrity_flags: expected.flags,
        p_duration_seconds: trajectoryDuration(outcome.trajectory),
        p_finished: finished,
        p_ghost_trajectory: ghost,
      }),
    });
    if (!apply.ok) {
      const detail = await apply.text();
      await failJob(`apply_run_result failed: ${detail}`);
      return { status: 500, body: { error: "result application failed" } };
    }

    return {
      status: 200,
      body: {
        runId,
        verdict: expected.verdict,
        score: expected.finalScore,
        breakdown: {
          paceBps: expected.paceBps,
          smoothnessBps: expected.smoothnessBps,
          controlBps: expected.controlBps,
          complianceBps: expected.complianceBps,
        },
        confidence: expected.confidenceScore,
        flags: expected.flags,
        finished,
      },
    };
  } catch (error) {
    await failJob(String(error));
    return { status: 500, body: { error: String(error) } };
  }
}

async function activeConfig(
  rest: (path: string, init?: RequestInit) => Promise<Response>,
): Promise<string> {
  const response = await rest(
    `/scoring_configs?active=eq.true&select=config&limit=1`,
  );
  const rows = await response.json();
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error("no active scoring config");
  }
  return JSON.stringify(rows[0].config);
}

// Edge-runtime entrypoint (deploys); tests import handleScoreRun directly.
if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "POST only" }), {
        status: 405,
        headers: { "Content-Type": "application/json" },
      });
    }
    const { runId } = await req.json().catch(() => ({ runId: null }));
    if (typeof runId !== "string") {
      return new Response(JSON.stringify({ error: "runId required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const authorization = req.headers.get("Authorization");
    if (authorization === null) {
      return new Response(JSON.stringify({ error: "authentication required" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }
    // Service-role callers are internal machinery (the stale-job sweeper) and
    // score on anyone's behalf. Everyone else is resolved from their JWT by
    // the auth server — never from the request body.
    let callerId: string | undefined;
    if (authorization !== `Bearer ${serviceKey}`) {
      const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
        headers: {
          apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
          Authorization: authorization,
        },
      });
      if (!userResponse.ok) {
        await userResponse.body?.cancel();
        return new Response(JSON.stringify({ error: "authentication required" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        });
      }
      const id = (await userResponse.json()).id;
      if (typeof id !== "string") {
        return new Response(JSON.stringify({ error: "authentication required" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        });
      }
      callerId = id;
    }
    const result = await handleScoreRun(runId, {
      restUrl: `${supabaseUrl}/rest/v1`,
      storageUrl: `${supabaseUrl}/storage/v1`,
      serviceKey,
    }, { callerId });
    return new Response(JSON.stringify(result.body), {
      status: result.status,
      headers: { "Content-Type": "application/json" },
    });
  });
}
