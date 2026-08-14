#!/usr/bin/env bash
# Accessibility guard rails for the iOS layer.
#
# Not a substitute for testing with VoiceOver and the largest text size on a
# real device — nothing here can be. It catches the two regressions that
# actually happened in this codebase and would happen again silently:
#
#   1. an interactive control smaller than Apple's 44pt minimum, including
#      "End run", which is pressed inside a moving car;
#   2. a fixed point size in live UI, which ignores Dynamic Type entirely.
#
# RunShareCard is exempt from (2) on purpose and the exemption is narrow:
# that view is rendered to a fixed-size PNG and shared with other people, so
# scaling it with the *sender's* text setting would change the exported
# image per device. The reasoning is written in the file itself.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# ── 1. tap targets ────────────────────────────────────────────────────────
# Only things you can PRESS. A badge or a chip with tight padding is fine;
# a Button with tight padding is a missed tap. 10*2 plus a footnote's ~17pt
# still falls short of 44.
while IFS= read -r hit; do
    file="${hit%%:*}"
    line="${hit#*:}"; line="${line%%:*}"
    # Is there a Button/NavigationLink just above? If not, this is a label.
    start=$((line - 6)); [ "$start" -lt 1 ] && start=1
    sed -n "${start},${line}p" "$file" | grep -q "Button\|NavigationLink\|ShareLink" || continue
    # A minHeight nearby is the accepted remedy.
    if ! sed -n "${start},$((line + 6))p" "$file" | grep -q "minHeight: 4[4-9]\|minHeight: [5-9][0-9]\|buttonStyle(Heat\|buttonStyle(Ghost"; then
        echo "a11y: $file:$line — pressable with vertical padding under 11pt and no 44pt minHeight"
        fail=1
    fi
done < <(grep -rn "padding(.vertical, \([0-9]\|10\))" App/Sources --include=*.swift || true)

# ── 2. Dynamic Type ───────────────────────────────────────────────────────
# Only SMALL fixed sizes are a defect. A 40-64pt display numeral already
# exceeds the largest Dynamic Type setting, so growing it breaks layout for
# no reader benefit — those are display type and stay fixed. Body-ish text
# below 34pt must scale.
fixed=$(grep -rn "font(.system(size: \([0-9]\|[12][0-9]\|3[0-3]\)[,)]" App/Sources --include=*.swift \
        | grep -v "Features/Results/RunResultView.swift" \
        | grep -v "DesignSystem/Components.swift" || true)
if [ -n "$fixed" ]; then
    count=$(printf '%s\n' "$fixed" | wc -l)
    echo "a11y: $count fixed font sizes outside the share card and design system:"
    printf '%s\n' "$fixed" | head -20
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "a11y-check: OK"
fi
exit "$fail"
