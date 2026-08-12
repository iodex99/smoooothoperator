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
| Adapters (CoreLocation/CoreMotion/StoreKit/SwiftData) | compile errors | not yet written |
| SwiftUI views | compile + layout | not yet written |
| Products.storekit | product ids must match App Store Connect | authored L0 |

## Decisions that constrain this layer

- Products: `smooooth.pro.weekly` / `.monthly` / `.yearly` in one subscription
  group. Prices come from App Store configuration — never hard-coded (spec §7).
- Background location: when-in-use + background updates during active
  challenge; honest usage strings; fallback plan if review objects is
  foreground-only recording with screen-lock guidance.
- Universal links: `smooooth.app/challenge/<CODE>` with custom-scheme fallback.
