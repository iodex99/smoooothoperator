# iOS Layer Notes — read before the first Mac session

> Living document. Everything unverifiable on Linux is tracked here so a Mac
> session is a checklist, not an archaeology dig.

## Why this file exists

The iOS layer (`App/`) is authored on Linux where it cannot be compiled.
Expect compile errors on first Mac open — that is planned, not failure.
The Kit (`SmoooothKit/`) is fully tested; keep fixes in the thin adapter/UI
layer and **never move logic out of the Kit to work around an error**.

## First Mac session checklist

1. `brew install xcodegen && cd App && xcodegen generate` → open the project.
2. Set the development team; verify bundle id `app.smooooth.operator`.
3. Build; fix adapter/view compile errors (expected).
4. Verify entitlements: Sign in with Apple, associated domains
   (`applinks:smooooth.app` — domain + AASA hosting must exist by then).
5. Run scheme uses `App/Configs/Products.storekit` — StoreKit sandbox test:
   purchase, restore, expiry of weekly/monthly/yearly.
6. Location permission flow: when-in-use + `allowsBackgroundLocationUpdates`
   during an active challenge only (blue-pill background mode, not Always).
7. Drive a short real course; compare recorded telemetry stats against
   simulator expectations (sample rates, accuracy distribution, gaps).
8. TestFlight build.

## Known-unverified inventory (keep current)

| Area | Risk | Status |
|---|---|---|
| `App/project.yml` | XcodeGen schema drift | authored L0, never generated |
| SensorFeed (CoreLocation+CoreMotion) | compile + timestamp-domain bridging (CMLogItem boot-time → epoch) needs device validation | authored, parse-gated |
| SupabaseAPI / RunUploader | compile; SUPABASE_URL/ANON_KEY must be added via xcconfig → Info.plist | authored, parse-gated |
| StoreKitSubscriptionService | compile; sandbox purchase/restore untested | authored, parse-gated |
| SwiftUI views (all 4 tabs + drive loop + paywall) | compile + layout; server feeds for Home/Explore/Friends are placeholders wired to real endpoints later | authored, parse-gated |
| MockSensorFeed (DEBUG) | drives the full DriveSession loop in the simulator without a car — use it on day 1 | authored |
| Products.storekit | product ids must match App Store Connect | authored L0 |
| Bundled `scoring-v1.json` fallback | add configs/scoring/v1.json to app resources in project.yml | TODO on Mac |

## Decisions that constrain this layer

- Products: `smooooth.pro.weekly` / `.monthly` / `.yearly` in one subscription
  group. Prices come from App Store configuration — never hard-coded (spec §7).
- Background location: when-in-use + background updates during active
  challenge; honest usage strings; fallback plan if review objects is
  foreground-only recording with screen-lock guidance.
- Universal links: `smooooth.app/challenge/<CODE>` with custom-scheme fallback.
