// Challenge format registry (directive 2026-08-13 §§6-7, 15).
//
// One GLOBAL format per day; every user gets a local course for it. Formats
// are data, not code paths: adding PRECISION_RUN later is a registry entry
// (and, if needed, a ranking-weight tweak) — never a rewrite. Scoring always
// goes through the existing engine (spec §86); a format may only bias which
// course gets selected, never how a run is scored.

export interface ChallengeFormat {
  key: string;
  title: string;
  tagline: string;
  /** Course-length window this format prefers, in meters (soft preference,
   * used by ranking — never a hard filter, low-density areas keep working). */
  preferredDistanceMeters: [number, number];
}

export const FORMATS: Record<string, ChallengeFormat> = {
  SMOOTH_SPRINT: {
    key: "SMOOTH_SPRINT",
    title: "Smooth Sprint",
    tagline: "Find your fastest smooth drive.",
    preferredDistanceMeters: [3_000, 20_000],
  },
  // Future formats land here: PRECISION_RUN, BALANCED_RUN, TECHNICAL_ROUTE,
  // CONSISTENCY_RUN, LONG_RUN (directive §7 — deliberately not implemented).
};

/** The global daily format. Configurable via env (CHALLENGE_FORMAT);
 * defaults to SMOOTH_SPRINT every day (directive §15). */
export function activeFormat(env: (key: string) => string | undefined): ChallengeFormat {
  const key = env("CHALLENGE_FORMAT") ?? "SMOOTH_SPRINT";
  return FORMATS[key] ?? FORMATS.SMOOTH_SPRINT;
}
