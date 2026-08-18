// The purge deletes people's raw location traces. The dangerous bug is not
// deleting too few — that only costs money and shows up in the backlog — it
// is marking a row `purged_at` whose blob is still in the bucket. Nothing
// would ever list that object again: it would sit there forever, paid for,
// holding a precise record of where somebody drove.
//
// So the rules asserted here are about what is marked, not about what is
// deleted, and each is driven by a stubbed Storage response.

import { assertEquals } from "jsr:@std/assert@1";
import { handlePurgeTelemetry } from "../purge-telemetry/index.ts";

const DEPS = { supabaseUrl: "http://stub", serviceKey: "stub-key" };

interface Stub {
  due: { telemetry_id: string; storage_path: string }[];
  /** Object names the Storage API reports it removed. */
  deleted: string[];
  storageStatus?: number;
}

/** Records what the function asked the database to mark. */
function install(stub: Stub): { marked: string[][]; restore: () => void } {
  const original = globalThis.fetch;
  const marked: string[][] = [];

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : {};

    if (url.endsWith("/rpc/telemetry_due_for_purge")) {
      return Promise.resolve(
        new Response(JSON.stringify(stub.due), { status: 200 }),
      );
    }
    if (url.endsWith("/rpc/mark_telemetry_purged")) {
      marked.push(body.ids);
      return Promise.resolve(
        new Response(JSON.stringify(body.ids.length), { status: 200 }),
      );
    }
    if (url.endsWith("/rpc/telemetry_purge_backlog")) {
      return Promise.resolve(
        new Response(JSON.stringify([{ due_count: 0 }]), { status: 200 }),
      );
    }
    if (url.includes("/storage/v1/object/telemetry")) {
      const status = stub.storageStatus ?? 200;
      return Promise.resolve(
        new Response(
          status === 200
            ? JSON.stringify(stub.deleted.map((name) => ({ name })))
            : "storage exploded",
          { status },
        ),
      );
    }
    throw new Error(`unexpected fetch: ${url}`);
  }) as typeof fetch;

  return { marked, restore: () => (globalThis.fetch = original) };
}

const row = (n: number) => ({
  telemetry_id: `00000000-0000-4000-8000-00000000000${n}`,
  storage_path: `user/${n}.json.gz`,
});

Deno.test("purge: marks exactly the blobs storage confirmed it deleted", async () => {
  const stub = install({
    due: [row(1), row(2)],
    deleted: ["user/1.json.gz", "user/2.json.gz"],
  });
  try {
    const { status, body } = await handlePurgeTelemetry(DEPS);
    assertEquals(status, 200);
    assertEquals(body.purged, 2);
    assertEquals(stub.marked, [[row(1).telemetry_id, row(2).telemetry_id]]);
  } finally {
    stub.restore();
  }
});

Deno.test("purge: a blob storage did NOT confirm is never marked", async () => {
  // The failure that must not happen. Storage removed one of the two; the
  // other must stay due, not be quietly recorded as gone.
  const stub = install({
    due: [row(1), row(2)],
    deleted: ["user/1.json.gz"],
  });
  try {
    const { body } = await handlePurgeTelemetry(DEPS);
    assertEquals(stub.marked, [[row(1).telemetry_id]]);
    assertEquals(body.purged, 1);
    assertEquals(body.errors.length, 1);
  } finally {
    stub.restore();
  }
});

Deno.test("purge: a storage failure marks nothing at all", async () => {
  const stub = install({
    due: [row(1), row(2)],
    deleted: [],
    storageStatus: 500,
  });
  try {
    const { status, body } = await handlePurgeTelemetry(DEPS);
    assertEquals(status, 502);
    assertEquals(body.purged, 0);
    assertEquals(body.remaining, 2);
    assertEquals(stub.marked, [], "nothing may be marked when storage failed");
  } finally {
    stub.restore();
  }
});

Deno.test("purge: an empty confirmation marks nothing", async () => {
  // Storage returned 200 with an empty list. That is not permission to mark
  // everything — it is permission to mark nothing.
  const stub = install({ due: [row(1)], deleted: [] });
  try {
    const { body } = await handlePurgeTelemetry(DEPS);
    assertEquals(body.purged, 0);
    assertEquals(body.remaining, 1);
    assertEquals(stub.marked, []);
  } finally {
    stub.restore();
  }
});

Deno.test("purge: nothing due does no work", async () => {
  const stub = install({ due: [], deleted: [] });
  try {
    const { status, body } = await handlePurgeTelemetry(DEPS);
    assertEquals(status, 200);
    assertEquals(body.purged, 0);
    assertEquals(body.remaining, 0);
    assertEquals(stub.marked, []);
  } finally {
    stub.restore();
  }
});
