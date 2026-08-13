// today-challenge — dynamic daily challenge selection (directive 2026-08-13).
//
// GET-shaped flow (directive §13):
//   user location → local date → cached assignment? return it
//   → else radius ladder (10/25/50/100 km) → challenge_candidates RPC
//   → deterministic ranking → best course → upsert assignment → respond.
//
// The response is fully drive-ready (course meta + polyline + gates) and
// fully honest: real participants, real bests, "set the first record" when
// nobody has driven it — never a fabricated competitor (directive §9).
//
// The handler core is exported so integration tests can drive it against a
// local stack without the edge runtime; Deno.serve wires it for deploys.

import { activeFormat, type ChallengeFormat, FORMATS } from "../_shared/challenge/formats.ts";
import { localDate, localDayStart } from "../_shared/challenge/localdate.ts";
import {
  type Candidate,
  radiiFromEnv,
  type RankedCandidate,
  rankCandidates,
  weightsFromEnv,
} from "../_shared/challenge/ranking.ts";

export interface TodayChallengeDeps {
  /** PostgREST base URL, e.g. http://127.0.0.1:54321/rest/v1 */
  restUrl: string;
  serviceKey: string;
  env?: (key: string) => string | undefined;
  now?: Date;
}

export interface TodayChallengeRequest {
  userId: string;
  latitude?: number;
  longitude?: number;
  /** IANA timezone from the device, e.g. "Europe/London". */
  timezone?: string;
  debug?: boolean;
}

async function rest(
  deps: TodayChallengeDeps,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  return await fetch(`${deps.restUrl}/${path}`, {
    ...init,
    headers: {
      apikey: deps.serviceKey,
      Authorization: `Bearer ${deps.serviceKey}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

async function rpc<T>(
  deps: TodayChallengeDeps,
  name: string,
  args: Record<string, unknown>,
): Promise<T> {
  const response = await rest(deps, `rpc/${name}`, {
    method: "POST",
    body: JSON.stringify(args),
  });
  if (!response.ok) {
    throw new Error(`${name}: ${response.status} ${await response.text()}`);
  }
  return await response.json() as T;
}

interface CourseMeta {
  id: string;
  name: string;
  city: string | null;
  country: string | null;
  distance_meters: number;
  estimated_duration_seconds: number | null;
  difficulty: number;
  turn_count: number;
  benchmark_seconds: number | null;
}

/** Builds the client payload for a selected course. */
async function buildChallenge(
  deps: TodayChallengeDeps,
  userId: string,
  format: ChallengeFormat,
  date: string,
  courseId: string,
  extras: {
    radiusKm: number | null;
    yourBest: number | null;
    friendBest: { score: number; username: string } | null;
    participantsToday: number;
  },
) {
  const metaResponse = await rest(
    deps,
    `courses?id=eq.${courseId}&select=id,name,city,country,distance_meters,estimated_duration_seconds,difficulty,turn_count,benchmark_seconds`,
  );
  const meta = (await metaResponse.json() as CourseMeta[])[0];
  if (!meta) return null;
  const route = await rpc<{ polyline: number[][]; gates: unknown[] } | null>(
    deps,
    "course_route",
    { uid: userId, cid: courseId },
  );
  if (!route || !route.polyline) return null;
  return {
    state: "ready",
    localDate: date,
    format: { key: format.key, title: format.title, tagline: format.tagline },
    course: {
      id: meta.id,
      name: meta.name,
      city: meta.city,
      country: meta.country,
      distanceMeters: meta.distance_meters,
      estimatedDurationSeconds: meta.estimated_duration_seconds,
      difficulty: meta.difficulty,
      turnCount: meta.turn_count,
      benchmarkSeconds: meta.benchmark_seconds,
      // GeoJSON order: [lon, lat].
      polyline: route.polyline,
      gates: route.gates,
    },
    yourBest: extras.yourBest,
    friendBest: extras.friendBest,
    participantsToday: extras.participantsToday,
    firstRecord: extras.yourBest === null && extras.friendBest === null &&
      extras.participantsToday === 0,
    radiusKm: extras.radiusKm,
  };
}

export async function handleTodayChallenge(
  request: TodayChallengeRequest,
  deps: TodayChallengeDeps,
): Promise<Record<string, unknown>> {
  const env = deps.env ?? ((key: string) => {
    try {
      return Deno.env.get(key);
    } catch {
      // No --allow-env (unit/integration runs): defaults apply.
      return undefined;
    }
  });
  const now = deps.now ?? new Date();
  const format = activeFormat(env);
  const lon = request.longitude ?? null;
  const date = localDate(request.timezone ?? null, lon, now);
  const dayStart = localDayStart(request.timezone ?? null, lon, now);

  // Fast path (directive §17): today's assignment already exists — rebuild
  // the (cheap) live extras and return it. No candidate search, no ranking.
  const cachedResponse = await rest(
    deps,
    `challenge_assignments?user_id=eq.${request.userId}&local_date=eq.${date}&select=course_id,format,radius_km,reason`,
  );
  const cached = (await cachedResponse.json() as {
    course_id: string;
    format: string;
    radius_km: number | null;
    reason: Record<string, unknown> | null;
  }[])[0];

  if (cached) {
    const extras = await liveExtras(deps, request, cached.course_id, dayStart);
    const cachedFriendBest = (cached.reason?.friendBest ?? null) as
      | { score: number; username: string }
      | null;
    const payload = await buildChallenge(
      deps, request.userId, FORMATS[cached.format] ?? format, date, cached.course_id,
      { radiusKm: cached.radius_km, ...extras, friendBest: cachedFriendBest },
    );
    if (payload) {
      return request.debug
        ? { ...payload, debug: { cache: "hit", reason: cached.reason } }
        : payload;
    }
    // Cached course vanished/became ineligible — fall through to reselect.
  }

  // No location and no cached assignment: an honest graceful state — a
  // driving challenge cannot be located without a location.
  if (request.latitude === undefined || request.longitude === undefined) {
    return {
      state: "unavailable",
      localDate: date,
      format: { key: format.key, title: format.title, tagline: format.tagline },
      message: "Allow location and Today's Challenge finds your local course.",
    };
  }

  // Radius ladder (directive §§2, 20): expand only while nothing suitable.
  const radii = radiiFromEnv(env);
  const weights = weightsFromEnv(env);
  let candidates: Candidate[] = [];
  let usedRadius = radii[radii.length - 1];
  const ladder: { radiusKm: number; candidates: number }[] = [];
  for (const radiusKm of radii) {
    candidates = await rpc<Candidate[]>(deps, "challenge_candidates", {
      uid: request.userId,
      origin_lat: request.latitude,
      origin_lon: request.longitude,
      radius_meters: radiusKm * 1000,
      day_start: dayStart.toISOString(),
    });
    ladder.push({ radiusKm, candidates: candidates.length });
    usedRadius = radiusKm;
    // Enough choice to rank meaningfully — stop expanding (never send
    // someone 100 km away when a good course sits nearby).
    if (candidates.length >= 3) break;
    if (candidates.length > 0 && radiusKm >= 25) break;
  }

  if (candidates.length === 0) {
    // Directive §20: graceful, honest, never fabricated.
    return {
      state: "coming-soon",
      localDate: date,
      format: { key: format.key, title: format.title, tagline: format.tagline },
      message: "Today's Challenge is coming to your area.",
      ...(request.debug ? { debug: { cache: "miss", ladder } } : {}),
    };
  }

  const ranked = rankCandidates(candidates, format, `${request.userId}:${date}`, weights);
  const winner = ranked[0];
  const reason = selectionReason(winner, ranked);

  // Persist the assignment (cache + rotation history + debug trail).
  await rest(deps, `challenge_assignments?on_conflict=user_id,local_date`, {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({
      user_id: request.userId,
      local_date: date,
      format: format.key,
      course_id: winner.candidate.course_id,
      radius_km: usedRadius,
      reason: {
        selected: winner.candidate.course_id,
        why: reason,
        ladder,
        friendBest: winner.candidate.friend_best_score !== null &&
            winner.candidate.friend_username !== null
          ? {
            score: winner.candidate.friend_best_score,
            username: winner.candidate.friend_username,
          }
          : null,
        scores: ranked.slice(0, 8).map((r) => ({
          course: r.candidate.name,
          id: r.candidate.course_id,
          score: Number(r.score.toFixed(4)),
          parts: Object.fromEntries(
            Object.entries(r.parts).map(([k, v]) => [k, Number(v.toFixed(4))]),
          ),
        })),
      },
    }),
  });

  const payload = await buildChallenge(
    deps, request.userId, format, date, winner.candidate.course_id,
    {
      radiusKm: usedRadius,
      yourBest: winner.candidate.your_best,
      friendBest: winner.candidate.friend_best_score !== null &&
          winner.candidate.friend_username !== null
        ? { score: winner.candidate.friend_best_score, username: winner.candidate.friend_username }
        : null,
      participantsToday: winner.candidate.participants_today,
    },
  );
  if (!payload) {
    return {
      state: "coming-soon",
      localDate: date,
      format: { key: format.key, title: format.title, tagline: format.tagline },
      message: "Today's Challenge is coming to your area.",
    };
  }
  return request.debug
    ? {
      ...payload,
      debug: {
        cache: "miss",
        ladder,
        reason,
        candidates: ranked.map((r) => ({
          name: r.candidate.name,
          score: Number(r.score.toFixed(4)),
        })),
      },
    }
    : payload;
}

/** Live per-course extras for the cache-hit path. */
async function liveExtras(
  deps: TodayChallengeDeps,
  request: TodayChallengeRequest,
  courseId: string,
  dayStart: Date,
): Promise<{
  yourBest: number | null;
  friendBest: { score: number; username: string } | null;
  participantsToday: number;
}> {
  // One candidates call scoped to the course's own start point would need
  // the point; instead reuse the RPC with a tiny radius around the user if
  // located, else fall back to direct queries.
  const bestResponse = await rest(
    deps,
    `leaderboard_entries?course_id=eq.${courseId}&user_id=eq.${request.userId}&select=score`,
  );
  const yourBest = ((await bestResponse.json()) as { score: number }[])[0]?.score ?? null;

  // Verified runs only — clients can insert run rows, so an unfiltered count
  // is inflatable. Migration 0014 closed this on the cache-MISS path; this is
  // the cache-hit path, which serves every request after the day's first.
  const participantsResponse = await rest(
    deps,
    `runs?course_id=eq.${courseId}&created_at=gte.${dayStart.toISOString()}`
      + `&verification=eq.verified&select=user_id`,
  );
  const participantRows = (await participantsResponse.json()) as { user_id: string }[];
  const participantsToday = new Set(participantRows.map((r) => r.user_id)).size;

  // Friend best via the SQL helper's rules would need a dedicated RPC; the
  // assignment's reason snapshot already carries it for the day. Keep the
  // cache-hit path lean: friend best from the ranking snapshot when needed.
  return { yourBest, friendBest: null, participantsToday };
}

function selectionReason(winner: RankedCandidate, ranked: RankedCandidate[]): string {
  const parts = winner.parts;
  const strongest = Object.entries(parts)
    .filter(([k]) => k !== "rotation")
    .sort((a, b) => b[1] - a[1])
    .slice(0, 2)
    .map(([k]) => ({
      proximity: "close by",
      quality: "high quality",
      freshness: "fresh for you",
      friendActivity: "friend activity",
      participation: "active today",
      formatFit: "fits the format",
    }[k] ?? k));
  const margin = ranked.length > 1 ? winner.score - ranked[1].score : winner.score;
  return `${strongest.join(" + ")} (margin ${margin.toFixed(3)} over ${ranked.length - 1} rivals)`;
}

// ── Edge runtime wiring ─────────────────────────────────────────────────────

function userIdFromJWT(header: string | null): string | null {
  if (!header?.startsWith("Bearer ")) return null;
  try {
    const payload = header.slice(7).split(".")[1];
    const claims = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
    return typeof claims.sub === "string" ? claims.sub : null;
  } catch {
    return null;
  }
}

if (import.meta.main) {
  Deno.serve(async (request) => {
    // The platform gateway verifies the JWT before invoking the function;
    // we only extract the subject here.
    const userId = userIdFromJWT(request.headers.get("Authorization"));
    if (!userId) {
      return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
    }
    let body: Record<string, unknown> = {};
    try {
      body = await request.json();
    } catch {
      // GET-style invocation without a body is fine.
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const payload = await handleTodayChallenge(
      {
        userId,
        latitude: typeof body.latitude === "number" ? body.latitude : undefined,
        longitude: typeof body.longitude === "number" ? body.longitude : undefined,
        timezone: typeof body.timezone === "string" ? body.timezone : undefined,
        debug: body.debug === true,
      },
      {
        restUrl: `${supabaseUrl}/rest/v1`,
        serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      },
    );
    return new Response(JSON.stringify(payload), {
      headers: { "Content-Type": "application/json" },
    });
  });
}
