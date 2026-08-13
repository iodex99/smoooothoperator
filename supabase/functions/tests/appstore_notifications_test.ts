// App Store Server Notifications: the security posture is the feature.
// These tests prove the endpoint refuses everything it cannot verify —
// a webhook that grants entitlements must never trust an unsigned payload.

import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  decodeNotification,
  handleNotification,
  statusFor,
  verifySignedPayload,
} from "../appstore-notifications/index.ts";

const deps = {
  restUrl: "http://127.0.0.1:1/rest/v1",
  serviceKey: "unused",
  appleRootCaSha256: "a".repeat(64),
};

function base64Url(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

Deno.test("without the pinned Apple root, the endpoint refuses to process anything", async () => {
  const result = await handleNotification("anything", {
    restUrl: deps.restUrl,
    serviceKey: deps.serviceKey,
    // appleRootCaSha256 deliberately absent
  });
  assertEquals(result.status, 503, "fails closed rather than trusting the payload");
});

Deno.test("a malformed JWS is rejected", async () => {
  const result = await handleNotification("not-a-jws", deps);
  assertEquals(result.status, 401);
});

Deno.test("an unsigned 'alg: none' payload is rejected", async () => {
  // The classic JWT forgery: claim there is no signature.
  const header = base64Url(JSON.stringify({ alg: "none", x5c: ["a", "b"] }));
  const payload = base64Url(JSON.stringify({ notificationType: "SUBSCRIBED" }));
  const result = await handleNotification(`${header}.${payload}.`, deps);
  assertEquals(result.status, 401);
});

Deno.test("a chain that is not Apple's is rejected even if well-formed", async () => {
  const header = base64Url(JSON.stringify({
    alg: "ES256",
    // Valid base64 that hashes to something other than the pin.
    x5c: [btoa("leaf"), btoa("root")],
  }));
  const payload = base64Url(JSON.stringify({ notificationType: "SUBSCRIBED" }));
  await assertRejects(
    () => verifySignedPayload(`${header}.${payload}.AAAA`, deps.appleRootCaSha256),
    Error,
  );
});

Deno.test("a payload with no certificate chain is rejected", async () => {
  const header = base64Url(JSON.stringify({ alg: "ES256" }));
  const payload = base64Url(JSON.stringify({ notificationType: "SUBSCRIBED" }));
  await assertRejects(
    () => verifySignedPayload(`${header}.${payload}.AAAA`, deps.appleRootCaSha256),
    Error,
    "missing certificate chain",
  );
});

// ── Apple's vocabulary → our status column ─────────────────────────────────

Deno.test("refunds and revocations remove entitlement immediately", () => {
  assertEquals(
    statusFor({
      notificationType: "REFUND",
      originalTransactionId: "1",
      transactionId: "1",
      productId: "p",
      environment: "Production",
      revoked: true,
    }),
    "revoked",
  );
});

Deno.test("a failed renewal in grace keeps access; billing retry does not", () => {
  const base = {
    notificationType: "DID_FAIL_TO_RENEW",
    originalTransactionId: "1",
      transactionId: "1",
    productId: "p",
    environment: "Production",
    revoked: false,
  };
  assertEquals(statusFor({ ...base, subtype: "GRACE_PERIOD" }), "in_grace_period");
  assertEquals(statusFor(base), "in_billing_retry");
});

Deno.test("cancelling auto-renew keeps access until the paid period ends", () => {
  assertEquals(
    statusFor({
      notificationType: "DID_CHANGE_RENEWAL_STATUS",
      subtype: "AUTO_RENEW_DISABLED",
      originalTransactionId: "1",
      transactionId: "1",
      productId: "p",
      environment: "Production",
      revoked: false,
    }),
    "active",
    "a cancellation is not an expiry — the user paid through the period",
  );
});

Deno.test("expiry and grace-period expiry both end entitlement", () => {
  for (const type of ["EXPIRED", "GRACE_PERIOD_EXPIRED"]) {
    assertEquals(
      statusFor({
        notificationType: type,
        originalTransactionId: "1",
      transactionId: "1",
        productId: "p",
        environment: "Production",
        revoked: false,
      }),
      "expired",
    );
  }
});

Deno.test("sandbox notifications are marked as sandbox, never production", async () => {
  const decoded = await decodeNotification(
    { notificationType: "SUBSCRIBED", data: { environment: "Sandbox" } },
    deps.appleRootCaSha256,
  );
  assertEquals(decoded.environment, "Sandbox");
});
