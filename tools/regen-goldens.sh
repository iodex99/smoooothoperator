#!/usr/bin/env bash
# Regenerate all golden fixtures via sogen. This is a deliberate act:
# the resulting diff encodes a scoring/pipeline behavior change and must be
# reviewed. Implementation lands in Phase L4 alongside `sogen generate`.
set -euo pipefail

echo "regen-goldens: not implemented until Phase L4 (sogen generate/score)" >&2
exit 1
