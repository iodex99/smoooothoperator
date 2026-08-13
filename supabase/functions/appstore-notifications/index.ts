// App Store Server Notifications V2 (spec §75).
//
// Without this endpoint the server never learns that anyone subscribed, so
// `has_active_pro()` is false for everyone — including paying customers,
// who are then refused the one Pro-gated feature. It is also the only way
// we hear about renewals, cancellations, refunds, billing retries and
// revocations, none of which the app can observe on its own.
//
// SECURITY POSTURE — fail closed. Apple signs every notification as a JWS
// whose header carries the signing certificate chain (x5c). We verify:
//   1. the signature, against the leaf certificate's public key;
//   2. that the chain terminates in Apple's root CA, pinned by SHA-256.
// If the pin is not configured we serve 503 rather than trust a payload —
// an unverified endpoint here is a "grant yourself Pro" button.

export interface NotificationDeps {
  restUrl: string;
  serviceKey: string;
  /** SHA-256 (hex, lowercase) of Apple's root CA certificate DER. */
  appleRootCaSha256?: string;
}

export interface DecodedNotification {
  notificationType: string;
  subtype?: string;
  originalTransactionId: string;
  productId: string;
  expiresDate?: number;
  environment: string;
  revoked: boolean;
}

const encoder = new TextEncoder();

function base64UrlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/")
    .padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

function base64ToBytes(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Extracts the SubjectPublicKeyInfo from a DER certificate and imports it
 * as an ECDSA P-256 key. Apple's signing certs are always P-256. */
async function publicKeyFromCertificate(der: Uint8Array): Promise<CryptoKey> {
  // The SPKI for a P-256 key ends with the 65-byte uncompressed point that
  // follows the id-ecPublicKey/prime256v1 OID pair. Locate that marker
  // rather than writing a general ASN.1 parser.
  const marker = [
    0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
  ];
  let index = -1;
  outer: for (let i = 0; i + marker.length < der.length; i++) {
    for (let j = 0; j < marker.length; j++) {
      if (der[i + j] !== marker[j]) continue outer;
    }
    index = i;
    break;
  }
  if (index < 0) throw new Error("certificate is not P-256");
  const spki = der.slice(index, index + marker.length + 2 + 66);
  return await crypto.subtle.importKey(
    "spki",
    spki,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
}

/** Verifies the JWS and returns its payload. Throws on anything suspicious. */
export async function verifySignedPayload(
  signedPayload: string,
  appleRootCaSha256: string,
): Promise<Record<string, unknown>> {
  const [headerPart, payloadPart, signaturePart] = signedPayload.split(".");
  if (!headerPart || !payloadPart || !signaturePart) {
    throw new Error("malformed JWS");
  }
  const header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(headerPart)));
  if (header.alg !== "ES256") throw new Error("unexpected algorithm");
  const chain: string[] = header.x5c ?? [];
  if (chain.length < 2) throw new Error("missing certificate chain");

  // The chain must terminate in the pinned Apple root.
  const rootDer = base64ToBytes(chain[chain.length - 1]);
  if (await sha256Hex(rootDer) !== appleRootCaSha256.toLowerCase()) {
    throw new Error("certificate chain is not Apple's");
  }

  const leafKey = await publicKeyFromCertificate(base64ToBytes(chain[0]));
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    base64UrlToBytes(signaturePart),
    encoder.encode(`${headerPart}.${payloadPart}`),
  );
  if (!verified) throw new Error("signature does not verify");

  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadPart)));
}

/** Flattens Apple's nested notification into what the subscriptions table needs. */
export async function decodeNotification(
  payload: Record<string, unknown>,
  appleRootCaSha256: string,
): Promise<DecodedNotification> {
  const data = (payload.data ?? {}) as Record<string, unknown>;
  const transaction = typeof data.signedTransactionInfo === "string"
    ? await verifySignedPayload(data.signedTransactionInfo, appleRootCaSha256)
    : {};
  const renewal = typeof data.signedRenewalInfo === "string"
    ? await verifySignedPayload(data.signedRenewalInfo, appleRootCaSha256)
    : {};
  const notificationType = String(payload.notificationType ?? "");
  return {
    notificationType,
    subtype: payload.subtype ? String(payload.subtype) : undefined,
    originalTransactionId: String(
      transaction.originalTransactionId ?? renewal.originalTransactionId ?? "",
    ),
    productId: String(transaction.productId ?? renewal.autoRenewProductId ?? ""),
    expiresDate: typeof transaction.expiresDate === "number"
      ? transaction.expiresDate
      : undefined,
    environment: String(data.environment ?? "Production"),
    // REFUND and REVOKE both mean: entitlement is gone, now.
    revoked: notificationType === "REFUND" || notificationType === "REVOKE"
      || transaction.revocationDate !== undefined,
  };
}

/** Apple's notification vocabulary → our status column. */
export function statusFor(notification: DecodedNotification): string {
  if (notification.revoked) return "revoked";
  switch (notification.notificationType) {
    case "EXPIRED":
      return "expired";
    case "GRACE_PERIOD_EXPIRED":
      return "expired";
    case "DID_FAIL_TO_RENEW":
      return notification.subtype === "GRACE_PERIOD"
        ? "in_grace_period"
        : "in_billing_retry";
    case "DID_CHANGE_RENEWAL_STATUS":
      // Cancelling auto-renew keeps access until the paid period ends.
      return "active";
    default:
      return "active";
  }
}

export async function handleNotification(
  signedPayload: string,
  deps: NotificationDeps,
): Promise<{ status: number; body: Record<string, unknown> }> {
  if (!deps.appleRootCaSha256) {
    // Fail closed: never process an unverifiable payload.
    return { status: 503, body: { error: "verification not configured" } };
  }
  let notification: DecodedNotification;
  try {
    const payload = await verifySignedPayload(signedPayload, deps.appleRootCaSha256);
    notification = await decodeNotification(payload, deps.appleRootCaSha256);
  } catch (error) {
    return { status: 401, body: { error: `rejected: ${error}` } };
  }
  if (notification.originalTransactionId === "") {
    return { status: 400, body: { error: "no transaction identity" } };
  }

  // Upsert by original_transaction_id — Apple's stable identity for a
  // subscription across every renewal. Idempotent by construction, which
  // matters because Apple retries notifications.
  const response = await fetch(
    `${deps.restUrl}/subscriptions?on_conflict=original_transaction_id`,
    {
      method: "POST",
      headers: {
        apikey: deps.serviceKey,
        Authorization: `Bearer ${deps.serviceKey}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates",
      },
      body: JSON.stringify({
        original_transaction_id: notification.originalTransactionId,
        product_id: notification.productId,
        status: statusFor(notification),
        expires_at: notification.expiresDate
          ? new Date(notification.expiresDate).toISOString()
          : null,
        environment: notification.environment === "Sandbox" ? "sandbox" : "production",
      }),
    },
  );
  if (!response.ok) {
    return {
      status: 500,
      body: { error: `persist failed: ${response.status} ${await response.text()}` },
    };
  }
  await response.body?.cancel();
  return {
    status: 200,
    body: { received: notification.notificationType, status: statusFor(notification) },
  };
}

if (import.meta.main) {
  Deno.serve(async (request) => {
    if (request.method !== "POST") {
      return new Response(JSON.stringify({ error: "POST only" }), { status: 405 });
    }
    const body = await request.json().catch(() => ({}));
    const signedPayload = typeof body.signedPayload === "string" ? body.signedPayload : "";
    if (!signedPayload) {
      return new Response(JSON.stringify({ error: "signedPayload required" }), {
        status: 400,
      });
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const result = await handleNotification(signedPayload, {
      restUrl: `${supabaseUrl}/rest/v1`,
      serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      appleRootCaSha256: Deno.env.get("APPLE_ROOT_CA_SHA256"),
    });
    return new Response(JSON.stringify(result.body), {
      status: result.status,
      headers: { "Content-Type": "application/json" },
    });
  });
}
