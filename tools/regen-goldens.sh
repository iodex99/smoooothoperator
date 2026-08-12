#!/usr/bin/env bash
# Regenerate all golden fixtures via sogen. This is a deliberate act: the
# resulting diff encodes a pipeline behavior change and must be reviewed
# like code. CI fails if committed goldens drift from the pipeline.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd SmoooothKit && swift build)
SmoooothKit/.build/debug/sogen goldens --out fixtures/golden --config configs/scoring/v1.json
echo
echo "regen-goldens: review the diff (git diff fixtures/golden) before committing."
