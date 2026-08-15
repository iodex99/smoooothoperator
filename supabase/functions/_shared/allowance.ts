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

/**
 * Courses one account may add to the catalog in a day.
 *
 * Course creation was gated on Pro and on nothing else, so a single $4.99
 * subscription could insert unbounded rows into the catalog EVERY driver
 * browses — the same table whose scan cost the browse work went to some
 * trouble to remove. Unlike the run allowance this is not about revenue:
 * Pro pays for the feature, and this only says how fast.
 *
 * Ten is far above real use and far below useful abuse. Making a course
 * means driving the road, so a person creating ten in a day has spent the
 * day driving; a script creating the eleventh has not.
 */
export const COURSES_PER_DAY = 10;

export function withinCourseAllowance(createdToday: number): boolean {
  return createdToday < COURSES_PER_DAY;
}
