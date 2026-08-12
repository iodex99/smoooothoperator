// Port of SmoooothKit SOCore/PiecewiseLinearCurve.swift.
// The ONLY nonlinearity permitted in scoring math (ADR-0002): keeps every
// computation inside + − × ÷, bit-identical between Swift Double and JS number.

export interface Breakpoint {
  x: number;
  y: number;
}

/**
 * A piecewise-linear response curve defined by breakpoints, evaluated by
 * linear interpolation and clamped at both ends.
 *
 * Throws unless there is ≥1 breakpoint with strictly increasing x — an
 * invalid curve is a config authoring error (Swift init? returns nil).
 */
export class PiecewiseLinearCurve {
  readonly breakpoints: readonly Breakpoint[];

  constructor(breakpoints: readonly Breakpoint[]) {
    if (breakpoints.length === 0) {
      throw new Error("PiecewiseLinearCurve requires at least one breakpoint");
    }
    for (let i = 1; i < breakpoints.length; i++) {
      if (breakpoints[i - 1].x >= breakpoints[i].x) {
        throw new Error(
          "PiecewiseLinearCurve breakpoints must have strictly increasing x",
        );
      }
    }
    this.breakpoints = breakpoints;
  }

  /**
   * Evaluate at `x`: clamped to the first/last y outside the domain, linear
   * interpolation between neighbors inside it. Mirrors the Swift linear scan.
   */
  valueAt(x: number): number {
    const first = this.breakpoints[0];
    const last = this.breakpoints[this.breakpoints.length - 1];
    if (x <= first.x) return first.y;
    if (x >= last.x) return last.y;

    for (let i = 1; i < this.breakpoints.length; i++) {
      const lower = this.breakpoints[i - 1];
      const upper = this.breakpoints[i];
      if (x <= upper.x) {
        const t = (x - lower.x) / (upper.x - lower.x);
        return lower.y + t * (upper.y - lower.y);
      }
    }
    return last.y; // unreachable
  }
}

/** Convenience for transcribing Swift `.init(x:y:)` breakpoint literals. */
export function curve(
  points: ReadonlyArray<[number, number]>,
): PiecewiseLinearCurve {
  return new PiecewiseLinearCurve(points.map(([x, y]) => ({ x, y })));
}
