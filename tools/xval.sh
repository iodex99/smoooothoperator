#!/usr/bin/env bash
# Cross-validate the Swift reference pipeline against the TypeScript port:
# both must reproduce every committed golden vector's expected.json exactly
# (ADR-0002). Run after any change to engines, simulator, or configs.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── Swift side: golden regression ──────────────────────────────"
(cd SmoooothKit && swift test --filter GoldenVectorTests)

echo "── TypeScript side: xval over the same vectors ────────────────"
(cd supabase/functions && deno test --allow-read=../../fixtures,../../configs tests/xval_test.ts)

echo "xval: both implementations reproduce all golden vectors."
