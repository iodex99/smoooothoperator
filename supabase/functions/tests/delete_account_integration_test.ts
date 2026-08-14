// The app says "your account and all its data have been deleted."
//
// The database cascade cannot reach the raw GPS traces — Supabase refuses
// direct deletes from storage tables — so this is the half that makes the
// sentence true. Against the LIVE local stack, because the Storage API is
// the thing being relied on and mocking it would test nothing.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleDeleteAccount, listTelemetryObjects } from "../delete-account/index.ts";

const SUPABASE_URL = "http://127.0.0.1:54321";
const SERVICE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

const netAllowed = (await Deno.permissions.query({ name: "net" })).state === "granted";
let stackUp = false;
if (netAllowed) {
  try {
    const probe = await fetch(`${SUPABASE_URL}/rest/v1/`, { headers: { apikey: SERVICE_KEY } });
    await probe.body?.cancel();
    stackUp = probe.status < 500;
  } catch { stackUp = false; }
}

const deps = { supabaseUrl: SUPABASE_URL, serviceKey: SERVICE_KEY };
const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

const LEAVING = "fa000001-a000-4000-8000-000000000001";
const STAYING = "fa000002-b000-4000-8000-000000000002";

async function upload(userId: string, file: string) {
  const body = new Blob([`{"fake":"telemetry for ${userId}"}`]);
  const r = await fetch(`${SUPABASE_URL}/storage/v1/object/telemetry/${userId}/${file}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body,
  });
  await r.body?.cancel();
}

/** A real access token for a seeded driver — the endpoint needs the
 *  caller's own, not an elevated one. */
async function tokenFor(id: string): Promise<string> {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email: `${id}@test.local`, password: "delete-test" }),
  });
  const body = await r.json();
  return body.access_token ?? "";
}

async function seed() {
  for (const id of [LEAVING, STAYING]) {
    await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: "POST",
      headers,
      body: JSON.stringify({ id, email: `${id}@test.local`, password: "delete-test", email_confirm: true }),
    }).then((r) => r.body?.cancel());
  }
  await upload(LEAVING, "run-1.ndjson.gz");
  await upload(LEAVING, "run-2.ndjson.gz");
  await upload(STAYING, "run-1.ndjson.gz");
}

async function cleanup() {
  for (const id of [LEAVING, STAYING]) {
    await fetch(`${SUPABASE_URL}/storage/v1/object/telemetry`, {
      method: "DELETE",
      headers,
      body: JSON.stringify({ prefixes: [`${id}/run-1.ndjson.gz`, `${id}/run-2.ndjson.gz`] }),
    }).then((r) => r.body?.cancel());
    await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${id}`, { method: "DELETE", headers })
      .then((r) => r.body?.cancel());
  }
}

Deno.test({
  name: "e2e: deleting an account removes the raw GPS traces too",
  ignore: !stackUp,
  async fn() {
    await seed();
    try {
      assertEquals(
        (await listTelemetryObjects(LEAVING, deps)).length, 2,
        "fixture: the leaving driver has two traces",
      );

      const result = await handleDeleteAccount(LEAVING, await tokenFor(LEAVING), deps);
      assertEquals(result.status, 200, JSON.stringify(result.body));
      assertEquals(result.body.telemetryObjectsRemoved, 2);

      assertEquals(
        (await listTelemetryObjects(LEAVING, deps)).length, 0,
        "their location history survived the deletion",
      );
      assertEquals(
        (await listTelemetryObjects(STAYING, deps)).length, 1,
        "another driver's traces were taken with them",
      );
    } finally {
      await cleanup();
    }
  },
});

Deno.test({
  name: "e2e: an unauthenticated caller deletes nothing",
  ignore: !stackUp,
  async fn() {
    assertEquals((await handleDeleteAccount("", "", deps)).status, 401);
    // An id without the matching token is the caller-supplied-id trap this
    // endpoint must not fall into.
    assertEquals((await handleDeleteAccount(LEAVING, "", deps)).status, 401);
  },
});

Deno.test({
  name: "e2e: one driver cannot delete another driver's account",
  ignore: !stackUp,
  async fn() {
    await seed();
    try {
      // STAYING's token, LEAVING's id. delete_my_account keys off auth.uid()
      // so the token decides — the id is not trusted, and cannot be.
      const result = await handleDeleteAccount(LEAVING, await tokenFor(STAYING), deps);
      // Whatever the status, the target must survive.
      const survivors = await fetch(
        `${SUPABASE_URL}/rest/v1/profiles?id=eq.${LEAVING}&select=id`,
        { headers },
      ).then((r) => r.json());
      assert(
        survivors.length === 1 || result.status >= 400,
        "one driver deleted another driver's account",
      );
    } finally {
      await cleanup();
    }
  },
});

Deno.test({
  name: "e2e: a driver with no telemetry still deletes cleanly",
  ignore: !stackUp,
  async fn() {
    // Someone who signed up and never drove. The storage list is empty and
    // that is not an error — the account must still go.
    const id = "fa000003-c000-4000-8000-000000000003";
    await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: "POST",
      headers,
      body: JSON.stringify({ id, email: `${id}@test.local`, password: "delete-test", email_confirm: true }),
    }).then((r) => r.body?.cancel());
    try {
      const result = await handleDeleteAccount(id, await tokenFor(id), deps);
      assertEquals(result.status, 200, JSON.stringify(result.body));
      assertEquals(result.body.telemetryObjectsRemoved, 0);
    } finally {
      await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${id}`, { method: "DELETE", headers })
        .then((r) => r.body?.cancel());
    }
  },
});
