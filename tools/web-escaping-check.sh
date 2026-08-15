#!/usr/bin/env bash
# The operator console builds its tables with innerHTML, and some of what it
# renders is typed by drivers — a custom course carries a name straight from
# whoever created it. Unescaped, a course named `<img src=x onerror=...>`
# runs its payload in the operator's session, which is the one account that
# can read the whole business and which holds a live admin token in that
# very page.
#
# This check is deliberately narrow. It cannot prove the page is safe; it
# pins the two structural decisions that make it safe, so removing either
# fails the build instead of failing silently on the day somebody names a
# course after a script tag.
set -euo pipefail

ADMIN="web/admin.html"
fail() { echo "web-escaping-check: $1" >&2; exit 1; }

[ -f "$ADMIN" ] || fail "$ADMIN is missing"

# 1. The escaper exists.
grep -q 'const esc = ' "$ADMIN" \
  || fail "the esc() helper is gone — every value interpolated into innerHTML needs it"

# 2. Table cells are escaped BY DEFAULT. The danger of the opposite default
#    is that forgetting it looks exactly like working code.
grep -q 'esc(c.cell(r))' "$ADMIN" \
  || fail "table cells are no longer escaped by default"

# 3. A column may opt out with `raw: true`, and exactly the columns that do
#    are the ones allowed to emit markup. Any cell producing a tag without
#    opting out is the bug this check exists for.
raw_columns=$(grep -c 'raw: true' "$ADMIN" || true)
markup_cells=$(grep -cE 'cell: \(x\) => `[^`]*<' "$ADMIN" || true)
if [ "$markup_cells" -gt "$raw_columns" ]; then
    fail "a cell emits markup without 'raw: true' ($markup_cells markup cells, $raw_columns opted out)"
fi

# 4. Nothing renders a driver-supplied field outside the escaped path.
#    These are the columns fed from `courses`, which a Pro driver creates.
for field in 'x.name' 'x.city' 'x.region' 'x.country'; do
    if grep -E "\\\$\{[^}]*${field//./\\.}" "$ADMIN" | grep -qv 'esc('; then
        fail "$field is interpolated into a template without esc()"
    fi
done

echo "web-escaping-check: OK"
