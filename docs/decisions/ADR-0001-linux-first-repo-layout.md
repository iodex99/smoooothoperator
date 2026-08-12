# ADR-0001: Linux-first repo layout — Kit/App hard boundary, XcodeGen

**Status:** accepted (2026-08-12)

## Context

Primary development happens in a Linux Codespace (Ubuntu 24.04, 2 cores, 8 GB).
Xcode and Apple SDKs are unavailable, but Swift toolchains for Linux exist and
Docker runs the Supabase stack. The product is a native iOS app whose value
rests on a trustworthy telemetry/scoring engine (spec §86).

## Decision

1. **All engine logic lives in `SmoooothKit`**, a SwiftPM package with zero
   third-party dependencies that builds and tests on Linux at every commit.
2. **Hard directory boundary, not `#if canImport(...)`:** SwiftPM on Linux never
   parses `App/`. Conditional compilation was rejected — a stray import or guard
   typo would break the one command that must always pass (`swift build`), and
   platform branches silently shrink test coverage. The boundary is mechanically
   enforced by `tools/kit-purity-check.sh` (CI).
3. **iOS project is generated with XcodeGen** from `App/project.yml`;
   `.xcodeproj` is gitignored. Rejected: Tuist (manifests are Swift executed by
   a macOS-only binary — unverifiable here; solves problems a one-app project
   doesn't have) and hand-maintained pbxproj (merge hell, not authorable on
   Linux). YAML is the smallest amount of unverifiable configuration, and all
   Apple-specific config (plist keys, entitlements, StoreKit) concentrates in
   one reviewable file.
4. **iOS layer stays thin** (adapters conforming to Kit protocols + SwiftUI
   layout). `swiftc -parse` gates syntax on Linux; a manual/nightly macOS CI
   job and budgeted Mac hardening sessions catch type errors.

## Consequences

- ~90% of product logic is continuously tested despite no Apple hardware.
- The iOS layer accumulates compile debt until a Mac session; this is accepted
  and tracked in docs/IOS-NOTES.md.
- Persistence logic must live behind Kit protocols (SwiftData only as a thin
  UI-cache adapter); in-flight telemetry recording uses a crash-safe
  append-only file whose logic is Linux-tested.
