#!/usr/bin/env bash
# Parse-check the iOS layer on Linux. `swiftc -parse` performs syntax parsing
# only (no import resolution, no type checking), so it works without Apple
# SDKs. It catches the "file doesn't even parse" class of blind-authoring
# drift; type errors are caught by the macOS nightly build / Mac sessions.
set -euo pipefail
cd "$(dirname "$0")/.."

mapfile -t files < <(find App/Sources App/Tests -name '*.swift' 2>/dev/null)

if [ ${#files[@]} -eq 0 ]; then
    echo "ios-syntax-check: no iOS sources yet — skipping"
    exit 0
fi

swiftc -parse "${files[@]}"
echo "ios-syntax-check: OK (${#files[@]} files parse)"
