# iOS Layer Notes — read before the first Mac session

> Living document. Everything unverifiable on Linux is tracked here so a Mac
> session is a checklist, not an archaeology dig.

## Why this file exists

The iOS layer (`App/`) is authored on Linux where it cannot be compiled.
**Status 2026-08-13: the app COMPILES, INSTALLS, LAUNCHES and renders in
the iOS Simulator on the CI Mac** (ios-nightly workflow: xcodegen → build →
simctl boot/install/launch → screenshot artifact). Across 17 blind-authored
files, exactly one compile error existed (SensorFeed Sendable). Trigger a
cycle with `git push origin main:ios-build`; screenshots land as run
artifacts. The user owns no Apple hardware — CI Macs are the only window,
and real-device sensor truth (one physical iPhone drive) remains the
launch-blocking gap no simulation can close.
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
| `App/project.yml` | XcodeGen schema drift | ✅ generates + builds on CI Mac (2026-08-13) |
| SensorFeed (CoreLocation+CoreMotion) | timestamp-domain bridging (CMLogItem boot-time → epoch) needs device validation | compiles on CI; device truth pending |
| SupabaseAPI / RunUploader | SUPABASE_URL/ANON_KEY must be added via xcconfig → Info.plist | compiles on CI |
| StoreKitSubscriptionService | sandbox purchase/restore untested | compiles on CI |
| SwiftUI views (all screens, heat design system) | layout verified via CI simulator screenshots; server feeds for Home/Explore/Friends are placeholders wired to real endpoints later | ✅ renders on CI simulator |
| CourseMapView (MapKit) | tiles need network; polyline/annotation rendering verified via CI screenshots | authored 2026-08-13 |
| DriveMapView (follow-cam) | camera glide + puck tracking need a real-drive sanity check; CI verifies rendering at 30× | authored 2026-08-13 |
| OnboardingView | page flow CI-captured; permission-priming copy final-checked at device stage | authored 2026-08-13 |
| AppIcon / LaunchBackground assets | asset catalog compiles on CI; icon renders on the simulator home screen | authored 2026-08-13 |
| RunShareCard (ImageRenderer @3×) | render output needs one visual check on device/simulator share sheet | authored 2026-08-13 |
| MockSensorFeed (DEBUG) | drives the full DriveSession loop in the simulator without a car — use it on day 1 | ✅ proven in CI demo tour |
| Products.storekit | product ids must match App Store Connect | authored L0 |
| Bundled `scoring-v1.json` fallback | keep in sync with configs/scoring/v1.json on scoring version bumps | ✅ bundled + proven in CI mock drive |

## Decisions that constrain this layer

- Products: `smooooth.pro.weekly` / `.monthly` / `.yearly` in one subscription
  group. Prices come from App Store configuration — never hard-coded (spec §7).
- Background location: when-in-use + background updates during active
  challenge; honest usage strings; fallback plan if review objects is
  foreground-only recording with screen-lock guidance.
- Universal links: `smooooth.app/challenge/<CODE>` with custom-scheme fallback.
