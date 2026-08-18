#!/usr/bin/env bash
# Refuses to let the e2e suite pass by not running.
#
# Every e2e test carries `ignore: !stackUp`, which is correct for a bare
# `deno test` on a machine with no Docker — a contributor running unit tests
# should not see nine red failures about a stack they never started.
#
# What that produces when the stack is only PARTLY up is a lie:
#
#     ok | 0 passed | 0 failed | 9 ignored
#
# Green, instantly, having tested nothing. This was the real state of things
# — the default `supabase start -x ...` in the runbook leaves PostgREST
# stopped, so the suite that covers scoring, course creation, account
# deletion and telemetry upload had been reporting success while running
# none of it.
#
# So `make e2e-test` now asks first, and says which service is missing
# rather than which URL returned what.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
# The standard local development key — identical on every machine, and not a
# secret. Real keys never live in this repo.
KEY="${SUPABASE_SERVICE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU}"

missing=()

probe() {
    local name="$1" path="$2" container="$3"
    local code
    # `|| code=000` and NOT `|| echo 000`: on a connection failure curl
    # prints 000 via -w *and* exits non-zero, so piping a second 000 in
    # produced the two-line string "000\n000". That matched neither branch
    # below, and `[ "000\n000" -ge 500 ]` fails as a bash syntax error rather
    # than as a condition — which, inside an `if`, reads as false. The check
    # then reported a dead PostgREST as healthy. Found by stopping the
    # container and watching this script pass.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "apikey: ${KEY}" -H "Authorization: Bearer ${KEY}" \
        "${URL}${path}" 2>/dev/null) || code=000
    # Anything that answers below 500 is the service being present. The e2e
    # tests supply their own auth; this only asks whether somebody is home.
    if ! [[ "$code" =~ ^[0-9]+$ ]] || [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
        missing+=("${name} (${path} -> ${code:-no response}) — ${container}")
        return 1
    fi
    printf '  %-10s ok\n' "$name"
}

echo "e2e-preflight: checking the local stack at ${URL}"

probe "postgrest" "/rest/v1/" "supabase_rest_*" || true
probe "storage"   "/storage/v1/bucket" "supabase_storage_*" || true
probe "auth"      "/auth/v1/settings" "supabase_auth_*" || true

if [ ${#missing[@]} -gt 0 ]; then
    cat >&2 <<EOF

e2e-preflight: FAILED — the stack is not fully up, so the e2e suite would
skip itself and report success. That is worse than failing.

Missing:
EOF
    for entry in "${missing[@]}"; do echo "  - ${entry}" >&2; done
    cat >&2 <<'EOF'

Start it with:

  supabase start -x studio,imgproxy,mailpit,logflare,vector,postgres-meta,realtime

If the stack is already running, one container is likely stopped from an
earlier partial start — PostgREST is the usual one, because the runbook's
`-x` list has excluded it in the past:

  docker start supabase_rest_smoooothoperator

EOF
    exit 1
fi

echo "e2e-preflight: OK (the suite will actually run)"
