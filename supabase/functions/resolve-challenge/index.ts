// resolve-challenge — invite-code share links (spec §79, L9).
//
// A share link must render a preview BEFORE signup, so this endpoint works
// for anonymous callers: it authenticates nobody and performs its lookups
// with the service role. That makes the response shape the security
// boundary — it returns ONLY safe public fields and never course geometry,
// checkpoint coordinates, run/telemetry data, or other participants'
// identities (the creator is public by construction: they sent the link).
//
// The handler core is exported so integration tests can drive it against a
// local stack without the edge runtime; Deno.serve wires it for deploys.

export interface ResolveChallengeDeps {
  /** PostgREST base URL, e.g. http://127.0.0.1:54321/rest/v1 */
  restUrl: string;
  serviceKey: string;
}

// Invite codes are 10 uppercase hex chars (challenges.invite_code default).
const INVITE_CODE_PATTERN = /^[0-9A-F]{10}$/;

export async function handleResolveChallenge(
  inviteCode: string,
  deps: ResolveChallengeDeps,
): Promise<{ status: number; body: Record<string, unknown> }> {
  if (
    typeof inviteCode !== "string" || !INVITE_CODE_PATTERN.test(inviteCode)
  ) {
    return { status: 400, body: { error: "invalid invite code format" } };
  }

  const headers = {
    apikey: deps.serviceKey,
    Authorization: `Bearer ${deps.serviceKey}`,
    "Content-Type": "application/json",
  };

  async function rest(path: string): Promise<Response> {
    return await fetch(`${deps.restUrl}${path}`, { headers });
  }

  try {
    const challenges = await (await rest(
      `/challenges?invite_code=eq.${inviteCode}` +
        `&select=id,name,type,status,expires_at,course_id,creator_id`,
    )).json();
    if (!Array.isArray(challenges) || challenges.length === 0) {
      return { status: 404, body: { error: "challenge not found" } };
    }
    const challenge = challenges[0];
    // Expired/cancelled links are dead links, indistinguishable from
    // unknown codes to the outside.
    const dead = challenge.status === "expired" ||
      challenge.status === "cancelled" ||
      (challenge.expires_at !== null &&
        new Date(challenge.expires_at).getTime() <= Date.now());
    if (dead) {
      return { status: 404, body: { error: "challenge not found" } };
    }

    const courses = await (await rest(
      `/courses?id=eq.${challenge.course_id}` +
        `&select=id,name,distance_meters,difficulty,turn_count,country`,
    )).json();
    if (!Array.isArray(courses) || courses.length === 0) {
      return { status: 404, body: { error: "challenge not found" } };
    }
    const course = courses[0];

    const profiles = await (await rest(
      `/profiles?id=eq.${challenge.creator_id}&select=username,display_name`,
    )).json();
    const creator = Array.isArray(profiles) && profiles.length > 0
      ? profiles[0]
      : null;

    const participants = await (await rest(
      `/challenge_participants?challenge_id=eq.${challenge.id}&select=id`,
    )).json();
    const participantCount = Array.isArray(participants)
      ? participants.length
      : 0;

    const entries = await (await rest(
      `/leaderboard_entries?course_id=eq.${course.id}` +
        `&user_id=eq.${challenge.creator_id}&select=score`,
    )).json();
    const creatorBestScore = Array.isArray(entries) && entries.length > 0
      ? entries[0].score
      : null;

    return {
      status: 200,
      body: {
        challenge: {
          id: challenge.id,
          name: challenge.name,
          type: challenge.type,
          status: challenge.status,
          expiresAt: challenge.expires_at,
        },
        course: {
          id: course.id,
          name: course.name,
          distanceMeters: course.distance_meters,
          difficulty: course.difficulty,
          turnCount: course.turn_count,
          country: course.country,
        },
        creator: {
          username: creator?.username ?? null,
          displayName: creator?.display_name ?? null,
        },
        participantCount,
        creatorBestScore,
      },
    };
  } catch (error) {
    return { status: 500, body: { error: String(error) } };
  }
}

// Edge-runtime entrypoint (deploys); tests import handleResolveChallenge
// directly. GET ?code=... for share-link fetches, POST {code} for clients.
if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    const json = (status: number, body: Record<string, unknown>) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
      });

    let code: unknown = null;
    if (req.method === "GET") {
      code = new URL(req.url).searchParams.get("code");
    } else if (req.method === "POST") {
      const body = await req.json().catch(() => null);
      code = body === null ? null : body.code;
    } else {
      return json(405, { error: "GET or POST only" });
    }
    if (typeof code !== "string") {
      return json(400, { error: "code required" });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const result = await handleResolveChallenge(code, {
      restUrl: `${supabaseUrl}/rest/v1`,
      serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    });
    return json(result.status, result.body);
  });
}
