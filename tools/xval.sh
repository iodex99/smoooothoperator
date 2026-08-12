#!/usr/bin/env bash
# Cross-validate the Swift reference scorer against the TypeScript port:
# both must produce identical quantized scores and verdicts on every golden
# vector in fixtures/golden. Full implementation lands in Phase L4 with the
# scoring engines; until then this passes when there is nothing to compare.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! compgen -G "fixtures/golden/*.telemetry.json" >/dev/null; then
    echo "xval: no golden vectors yet (Phase L4) — skipping"
    exit 0
fi

echo "xval: golden vectors exist but the comparison harness is not implemented yet" >&2
exit 1
