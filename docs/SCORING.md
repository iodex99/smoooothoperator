# Scoring

> Living document. The scoring model is versioned; this file documents the
> current version and the invariants that keep client and server identical.

## Model (v1, spec §§38–43)

Final score = weighted combination of four sub-scores, each 0–10,000 basis points:

| Sub-score | Weight (v1) | Measures |
|---|---|---|
| Pace | 35% | Efficiency vs. course benchmark and difficulty — never rewards illegal speed |
| Smoothness | 35% | Acceleration/braking smoothness, jerk, lateral G, oscillation |
| Control | 20% | Consistency of cornering, braking, acceleration; unnecessary corrections |
| Compliance | 10% | Speed-limit and route adherence **where data is reliable** |

Principles: smooth ≠ slow (crawling every corner must not win); fast ≠ reckless;
violations are only inferred from high-confidence data; serious violations make
a run ineligible for leaderboards rather than merely scoring low.

## Configuration

`configs/scoring/v1.json` (lands with L4) is the single source of truth, loaded
by both the Swift and TypeScript scorers. It contains: version, weights,
piecewise-linear response curves (breakpoint tables evaluated by lerp),
thresholds, penalties, confidence requirements. Nothing scoring-related is
hard-coded in app code. Every run stores its `scoringVersion`; old runs keep
the score their version produced (spec §43).

## Determinism invariants (make Swift ≡ TypeScript provable)

1. Scoring math uses only `+ − × ÷ √` — IEEE-754 correctly-rounded and
   bit-identical between Swift `Double` and JS `number`. **No transcendentals**
   (`pow`, `exp`, `log`, trig) anywhere in scoring. Curves are piecewise-linear.
2. Sub-scores are quantized to integer basis points (0–10,000) with a specified
   rounding rule **before** weighting.
3. The final combination is exact integer arithmetic
   (`ScoreBreakdown.finalScore` in `SOScoring`; operation order mirrored in TS).
4. `make xval` proves both implementations produce byte-identical final scores
   and verdicts on every golden vector. CI-enforced.

Adding any non-linear response? Add breakpoints to the curve table instead.
If a genuine transcendental ever becomes unavoidable, it must be quantized at
a defined precision at the point of use and cross-validated — see ADR-0002.
