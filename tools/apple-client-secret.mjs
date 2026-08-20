#!/usr/bin/env node
// Generate the Apple client secret JWT that Supabase's
// "Secret Key (for OAuth)" field expects.
//
//   node tools/apple-client-secret.mjs path/to/AuthKey_J93DS8ADR3.p8
//
// No dependencies — uses node:crypto only. The .p8 never leaves this machine.

import { createSign, createPrivateKey } from 'node:crypto';
import { readFileSync } from 'node:fs';

const TEAM_ID    = '44R2VVGF8G';                    // issuer
const KEY_ID     = 'J93DS8ADR3';                    // key header
const SERVICE_ID = 'app.smooooth.operator.signin';  // subject — the Services ID, not the App ID
const MAX_LIFETIME = 15777000;                      // Apple's hard cap: 6 months, in seconds

const p8Path = process.argv[2];
if (!p8Path) {
  console.error('usage: node tools/apple-client-secret.mjs <path-to-.p8>');
  process.exit(1);
}

let pem;
try {
  pem = readFileSync(p8Path, 'utf8');
} catch (e) {
  console.error(`cannot read ${p8Path}: ${e.message}`);
  process.exit(1);
}

if (!pem.includes('BEGIN PRIVATE KEY')) {
  console.error('That file is not a PKCS#8 private key.');
  console.error('An Apple .p8 starts with "-----BEGIN PRIVATE KEY-----".');
  process.exit(1);
}

const b64u = (x) => Buffer.from(x).toString('base64url');
const now  = Math.floor(Date.now() / 1000);
const exp  = now + MAX_LIFETIME;

const header  = { alg: 'ES256', kid: KEY_ID };
const payload = {
  iss: TEAM_ID,
  iat: now,
  exp,
  aud: 'https://appleid.apple.com',
  sub: SERVICE_ID,
};

const signingInput = `${b64u(JSON.stringify(header))}.${b64u(JSON.stringify(payload))}`;

let signature;
try {
  const key = createPrivateKey(pem);
  if (key.asymmetricKeyType !== 'ec') {
    console.error(`Expected an EC key, got ${key.asymmetricKeyType}. Wrong .p8?`);
    process.exit(1);
  }
  const signer = createSign('SHA256');
  signer.update(signingInput);
  // ieee-p1363 = raw r||s, which is what JWS ES256 requires (not DER).
  signature = signer.sign({ key, dsaEncoding: 'ieee-p1363' });
} catch (e) {
  console.error(`signing failed: ${e.message}`);
  process.exit(1);
}

const jwt = `${signingInput}.${b64u(signature)}`;

console.error('--- paste this into Supabase > Authentication > Sign In / Providers > Apple > Secret Key ---');
console.log(jwt);
console.error(`--- expires ${new Date(exp * 1000).toISOString().slice(0, 10)} — set a reminder, sign-in breaks silently when it lapses ---`);
