# Smooooth Operator

**Drive smooth. Finish fast.**

A competitive driving iOS app: take on real-world courses and compete with
friends and drivers worldwide to complete them as quickly, smoothly and
**legally** as possible. Fast + smooth + controlled + legal — never fastest
at any cost.

## Repository layout

| Path | What it is |
|---|---|
| `SmoooothKit/` | SwiftPM package — every engine (telemetry, scoring, integrity, ghosts, courses, sync). Builds and tests on **Linux**. |
| `App/` | iOS app layer (SwiftUI + platform adapters). Authored here, compiled on macOS via XcodeGen. |
| `supabase/` | Backend: migrations (RLS everywhere), edge functions, pgTAP tests. |
| `fixtures/` | Golden telemetry vectors shared by Swift and TypeScript test suites. |
| `configs/scoring/` | Versioned scoring configuration consumed by both scorer implementations. |
| `docs/` | Living documentation — updated every phase. Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). |
| `tools/` | CI guard scripts (kit purity, iOS syntax gate, cross-validation). |

## Development quickstart (Linux)

```bash
# toolchain (once): Swift 6.1.3 for Ubuntu 24.04 + Supabase CLI + Deno
export PATH=$HOME/toolchains/swift-6.1.3/usr/bin:$HOME/.deno/bin:$PATH

make kit-test    # build + test the engines
supabase start -x studio,imgproxy,mailpit,logflare,vector,postgres-meta,edge-runtime,realtime
make db-test     # pgTAP schema + RLS tests
make test        # everything Linux-verifiable
```

The iOS app itself is generated on a Mac: see [docs/IOS-NOTES.md](docs/IOS-NOTES.md).

## Project status

See [docs/ROADMAP.md](docs/ROADMAP.md) for the phase ledger. Current phase: **L0 — Foundation**.
