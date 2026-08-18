// Retention: raw telemetry blobs are deleted after the retention window.
//
// The blobs are ~2.5 MB each and dominate storage by three orders of
// magnitude, and they are the most sensitive thing this product holds — a
// precise record of where somebody drove, usually starting at their home.
// Nothing in the product reads one after it has been scored: the run, its
// sub-scores, its ghost and its preview polyline are all derived at scoring
// time and kept. So they go, and the envelope (hash, counts, path) stays as
// the honest record that the data existed.
//
// The database decides WHICH blobs are due — see migration 0035, which also
// documents what is deliberately never purged — and this function does the
// deleting, because Supabase guards `storage.objects` with a trigger that
// refuses direct SQL deletes.
//
// ORDER MATTERS, and it is the opposite of `delete-account`'s. There, the
// blobs go before the rows, so a failure never orphans a file. Here the row
// is marked only AFTER the object is confirmed gone: a crash mid-batch must
// leave work to redo, never a `purged_at` on a blob that is still sitting in
// the bucket costing money and holding somebody's location history.

export interface PurgeTelemetryDeps {
  /** e.g. http://127.0.0.1:54321 */
  supabaseUrl: string;
  serviceKey: string;
}

const BUCKET = "telemetry";

/** How many blobs one invocation will remove. */
export const BATCH_SIZE = 100;

interface DueRow {
  telemetry_id: string;
  storage_path: string;
}

export interface PurgeResult {
  /** Blobs actually deleted from storage and marked in the database. */
  purged: number;
  /** Rows still due after this batch — a nudge to run again. */
  remaining: number;
  errors: string[];
}

async function rpc<T>(
  name: string,
  body: unknown,
  deps: PurgeTelemetryDeps,
): Promise<T> {
  const response = await fetch(`${deps.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: deps.serviceKey,
      Authorization: `Bearer ${deps.serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`${name} failed: ${response.status} ${detail}`);
  }
  return await response.json() as T;
}

export async function handlePurgeTelemetry(
  deps: PurgeTelemetryDeps,
  batchSize: number = BATCH_SIZE,
): Promise<{ status: number; body: PurgeResult }> {
  const errors: string[] = [];
  const due = await rpc<DueRow[]>(
    "telemetry_due_for_purge",
    { batch_size: batchSize },
    deps,
  );

  if (due.length === 0) {
    return { status: 200, body: { purged: 0, remaining: 0, errors } };
  }

  // One Storage call for the whole batch. The API takes a list of prefixes
  // and reports what it removed.
  const removed = await fetch(`${deps.supabaseUrl}/storage/v1/object/${BUCKET}`, {
    method: "DELETE",
    headers: {
      apikey: deps.serviceKey,
      Authorization: `Bearer ${deps.serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ prefixes: due.map((row) => row.storage_path) }),
  });

  if (!removed.ok) {
    const detail = await removed.text();
    // Nothing is marked. The batch is retried next run, which is the correct
    // outcome for a transient storage failure.
    return {
      status: 502,
      body: {
        purged: 0,
        remaining: due.length,
        errors: [`storage delete failed: ${removed.status} ${detail}`],
      },
    };
  }

  // Only rows the Storage API CONFIRMED it removed are marked. Marking one
  // it did not confirm would strand the blob forever: nothing would ever
  // list it again, and it would sit in the bucket holding somebody's
  // location history and being paid for. An unconfirmed row simply stays
  // due, and `telemetry_purge_backlog` makes a batch that never drains
  // visible instead of silent.
  const deleted = await removed.json() as { name: string }[];
  const deletedNames = new Set(deleted.map((object) => object.name));
  const gone = due.filter((row) => deletedNames.has(row.storage_path));
  const stillThere = due.length - gone.length;
  if (stillThere > 0) {
    errors.push(
      `${stillThere} object(s) were not confirmed deleted and stay due`,
    );
  }
  if (gone.length === 0) {
    return { status: 200, body: { purged: 0, remaining: due.length, errors } };
  }

  const marked = await rpc<number>(
    "mark_telemetry_purged",
    { ids: gone.map((row) => row.telemetry_id) },
    deps,
  );

  const backlog = await rpc<{ due_count: number }[]>(
    "telemetry_purge_backlog",
    {},
    deps,
  );

  return {
    status: 200,
    body: {
      purged: marked,
      remaining: Number(backlog[0]?.due_count ?? 0),
      errors,
    },
  };
}

if (import.meta.main) {
  Deno.serve(async (request: Request) => {
    // Service-role only. There is no user-facing reason to call this, and a
    // caller who could would be deleting other people's data.
    const auth = request.headers.get("Authorization") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!serviceKey || auth !== `Bearer ${serviceKey}`) {
      return new Response(JSON.stringify({ error: "forbidden" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }
    try {
      const { status, body } = await handlePurgeTelemetry({
        supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
        serviceKey,
      });
      return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
      });
    } catch (error) {
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
  });
}
