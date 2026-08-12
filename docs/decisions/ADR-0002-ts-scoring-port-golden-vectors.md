# ADR-0002: Server-authoritative scoring via TypeScript port + golden vectors

**Status:** accepted (2026-08-12)

## Context

The server must produce the authoritative score (spec §46) — a client cannot be
trusted to submit scores. Supabase edge functions run Deno/TypeScript; the
reference scoring implementation is Swift (SmoooothKit). Three options:

- **(a) TypeScript reimplementation** of scoring + deterministic integrity checks.
- **(b) Swift → wasm** in the edge function: partial Foundation, 10–40 MB
  bundles vs. edge limits, slow cold starts, experimental toolchain in CI.
- **(c) Containerized Swift scoring service:** Supabase hosts no containers →
  second deploy target, second auth path, second bill, RLS story punctured.

## Decision

**(a) TS port**, kept provably equivalent by simulator-generated golden vectors,
plus two design rules that make cross-language equivalence cheap:

1. **Piecewise-linear response curves** in the versioned ScoringConfig
   (breakpoint tables + lerp). Scoring math restricted to `+ − × ÷ √` — all
   IEEE-754 correctly-rounded, bit-identical between Swift `Double` and JS
   `number`. No transcendentals in scoring, ever.
2. **Integer quantization before weighting:** sub-scores become integer basis
   points (0–10,000), the 35/35/20/10 combination is exact integer arithmetic
   with mirrored operation order (`ScoreBreakdown.finalScore`).

Cross-validation: `sogen` emits `fixtures/golden/*.telemetry.json` +
`.expected.json`; Swift tests and Deno tests both assert exact equality of
quantized sub-scores, final score, and verdict; CI job `xval` runs on every
push. Swift is the *reference* implementation; TS is the *operationally
authoritative* one; CI equivalence makes the distinction moot.

## Consequences

- Dual maintenance of scoring code — bounded because scoring is a pure function
  and every change must regenerate goldens (`make regen-goldens`) with a
  reviewable diff.
- Server-side telemetry processing in TS was unavoidable anyway (integrity
  checks must run server-side), so the port is not net-new surface.
- If scoring load or complexity ever outgrows this, revisit (c) with the
  then-current constraints.
