#!/usr/bin/env bash
# Enforce Kit purity: SmoooothKit must build on Linux, so Apple-only
# frameworks are forbidden in its sources. The iOS layer in /App is the only
# place allowed to import them (behind the Kit's protocols).
set -euo pipefail
cd "$(dirname "$0")/.."

FORBIDDEN='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(SwiftUI|UIKit|AppKit|WatchKit|CoreLocation|CoreMotion|MapKit|StoreKit|SwiftData|CoreData|CoreHaptics|Combine|CloudKit|HealthKit|WidgetKit|ActivityKit)\b'

if matches=$(grep -rEn "$FORBIDDEN" SmoooothKit/Sources 2>/dev/null); then
    echo "KIT PURITY VIOLATION — Apple-only imports found in SmoooothKit:"
    echo "$matches"
    echo
    echo "Move platform code to App/Sources/Adapters behind a Kit protocol."
    exit 1
fi

echo "kit-purity-check: OK (no Apple-only imports in SmoooothKit/Sources)"
