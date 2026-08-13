// The free tier's daily run limit, server side.
//
// The client enforces the same rule for UX (SmoooothKit's DailyRunAllowance),
// but a client-side limit is a suggestion: it resets on reinstall, on a
// device clock change, and on any modified build. If the limit is meant to
// protect revenue it has to hold here too.
//
// Keep this number in sync with SmoooothKit/Sources/SOSync/DailyRunAllowance.
export const FREE_RUNS_PER_DAY = 3;

/** UTC day bounds — deliberately NOT the user's local day: the server must
 * not accept a client-supplied timezone as an input to a paid boundary. */
export function utcDayStart(now: Date = new Date()): string {
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()),
  ).toISOString();
}

export function withinAllowance(scoredToday: number, isPro: boolean): boolean {
  return isPro || scoredToday < FREE_RUNS_PER_DAY;
}
