// Account deletion, in full (spec §62, and the promise the app makes).
//
// The database cascade reaches every ROW: profile, runs, vehicles, ghosts,
// leaderboard entries, friendships, telemetry pointers. It cannot reach the
// telemetry BLOBS — the raw GPS traces — because Supabase protects storage
// tables with a trigger that refuses direct deletes and points callers at
// the Storage API.
//
// So the blobs go first, here, and only then the rows. That order matters:
// after the cascade there are no telemetry rows left to find the files by,
// and a failure at that point would leave someone's complete location
// history behind with nothing pointing at it.
//
// The handler core is exported so tests can drive it without the edge
// runtime; Deno.serve wires it for deploys.

export interface DeleteAccountDeps {
  /** e.g. http://127.0.0.1:54321 */
  supabaseUrl: string;
  serviceKey: string;
}

const BUCKET = "telemetry";

/** Every telemetry object stored under a driver's prefix. */
export async function listTelemetryObjects(
  userId: string,
  deps: DeleteAccountDeps,
): Promise<string[]> {
  const names: string[] = [];
  let offset = 0;
  // Paged: a heavy user has hundreds of runs, and a single unpaged list
  // would silently stop at the server's limit — leaving files behind while
  // reporting success.
  for (;;) {
    const response = await fetch(
      `${deps.supabaseUrl}/storage/v1/object/list/${BUCKET}`,
      {
        method: "POST",
        headers: {
          apikey: deps.serviceKey,
          Authorization: `Bearer ${deps.serviceKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ prefix: `${userId}/`, limit: 100, offset }),
      },
    );
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`storage list failed: ${response.status}`);
    }
    const page = await response.json() as { name: string }[];
    if (page.length === 0) break;
    names.push(...page.map((o) => `${userId}/${o.name}`));
    if (page.length < 100) break;
    offset += page.length;
  }
  return names;
}

export async function handleDeleteAccount(
  userId: string,
  /** The CALLER's own token. */
  userToken: string,
  deps: DeleteAccountDeps,
): Promise<{ status: number; body: Record<string, unknown> }> {
  if (!userId || !userToken) {
    return { status: 401, body: { error: "authentication required" } };
  }

  try {
    const objects = await listTelemetryObjects(userId, deps);

    if (objects.length > 0) {
      const removed = await fetch(`${deps.supabaseUrl}/storage/v1/object/${BUCKET}`, {
        method: "DELETE",
        headers: {
          apikey: deps.serviceKey,
          Authorization: `Bearer ${deps.serviceKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ prefixes: objects }),
      });
      if (!removed.ok) {
        const detail = await removed.text();
        await removed.body?.cancel();
        // Fail CLOSED. Deleting the account while its traces survive would
        // leave data nobody can reach, delete or even find — and the app
        // would have said it was gone.
        return {
          status: 502,
          body: { error: `could not remove telemetry: ${detail}` },
        };
      }
      await removed.body?.cancel();
    }

    // Now the rows — with the CALLER's token, deliberately.
    //
    // delete_my_account keys off auth.uid() and is granted to authenticated
    // only. Calling it with the service role fails, and that is the right
    // design: there is no variant that takes a user id, so this endpoint
    // cannot be talked into deleting somebody else's account. The elevated
    // key is used for storage and nothing more.
    const rpc = await fetch(`${deps.supabaseUrl}/rest/v1/rpc/delete_my_account`, {
      method: "POST",
      headers: {
        apikey: deps.serviceKey,
        Authorization: `Bearer ${userToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    });
    if (!rpc.ok) {
      const detail = await rpc.text();
      return { status: 500, body: { error: `account deletion failed: ${detail}` } };
    }
    await rpc.body?.cancel();

    return { status: 200, body: { deleted: true, telemetryObjectsRemoved: objects.length } };
  } catch (error) {
    return { status: 500, body: { error: String(error) } };
  }
}

if (import.meta.main) {
  Deno.serve(async (req: Request) => {
    const json = (status: number, body: Record<string, unknown>) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
      });

    if (req.method !== "POST") return json(405, { error: "POST only" });

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    if (!supabaseUrl || !serviceKey) return json(500, { error: "not configured" });

    // The CALLER is resolved from their own JWT — never from the body.
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
    if (!token) return json(401, { error: "authentication required" });
    const who = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
    });
    if (!who.ok) {
      await who.body?.cancel();
      return json(401, { error: "authentication required" });
    }
    const user = await who.json() as { id?: string };
    if (!user.id) return json(401, { error: "authentication required" });

    const result = await handleDeleteAccount(user.id, token, { supabaseUrl, serviceKey });
    return json(result.status, result.body);
  });
}
