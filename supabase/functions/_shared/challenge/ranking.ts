// Today's Challenge course ranking (directive §§4-5, 14) — pure and
// deterministic so it is trivially unit-testable and identical on every
// invocation for a given (user, day). No ML, no randomness: rotation
// variety comes from a seeded hash, never Math.random().

import type { ChallengeFormat } from "./formats.ts";

/** Row shape returned by the challenge_candidates SQL function. */
export interface Candidate {
  course_id: string;
  name: string;
  proximity_km: number;
  distance_meters: number;
  estimated_duration_seconds: number | null;
  difficulty: number;
  turn_count: number;
  benchmark_seconds: number | null;
  verified_drivers: number;
  days_since_user_drove: number | null;
  days_since_assigned: number | null;
  friend_best_score: number | null;
  friend_username: string | null;
  friend_days_ago: number | null;
  participants_today: number;
  your_best: number | null;
}

/** Weights are configuration, not code (directive §14). */
export interface RankingWeights {
  proximity: number;
  quality: number;
  freshness: number;
  friendActivity: number;
  participation: number;
  formatFit: number;
}

export const DEFAULT_WEIGHTS: RankingWeights = {
  proximity: 0.28,
  quality: 0.22,
  freshness: 0.24,
  friendActivity: 0.12,
  participation: 0.06,
  formatFit: 0.08,
};

export interface RankedCandidate {
  candidate: Candidate;
  score: number;
  parts: Record<string, number>;
}

/** Deterministic hash → [0, 1). Rotates ties day-to-day per user without
 * fabricating anything. */
export function rotationJitter(seed: string): number {
  let hash = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    hash ^= seed.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) / 4294967296;
}

/** Ranks candidates for one user's daily challenge. `seed` should be
 * `${userId}:${localDate}` so selection is stable within a day and varies
 * across days. Returns best-first. */
export function rankCandidates(
  candidates: Candidate[],
  format: ChallengeFormat,
  seed: string,
  weights: RankingWeights = DEFAULT_WEIGHTS,
): RankedCandidate[] {
  const ranked = candidates.map((candidate) => {
    // Closer is better; ~10 km is still comfortable, 50 km is a trek.
    const proximity = 1 / (1 + candidate.proximity_km / 10);

    // Quality: catalog courses are validator-vetted by construction, so the
    // strongest available signal is real verified drivers; a reference
    // benchmark and real turns mark a deliberately built course.
    const drivers = Math.min(candidate.verified_drivers, 20) / 20;
    const quality = 0.5 * drivers +
      (candidate.benchmark_seconds !== null ? 0.3 : 0) +
      (candidate.turn_count >= 4 ? 0.2 : 0.1);

    // Freshness: never seen = 1; driven/assigned yesterday ≈ 0; fully
    // recovered after a week. The recency of BOTH driving and being shown
    // counts (directive §4).
    const daysSince = Math.min(
      candidate.days_since_user_drove ?? 99,
      candidate.days_since_assigned ?? 99,
    );
    const freshness = Math.min(daysSince, 7) / 7;

    // Friend activity (directive §10): a friend on the board this week is a
    // strong pull; an older friend entry still beats silence.
    const friendActivity = candidate.friend_best_score === null
      ? 0
      : (candidate.friend_days_ago !== null && candidate.friend_days_ago <= 7 ? 1 : 0.4);

    // Real participants today only — zero stays zero (directive §§9, 12).
    const participation = Math.min(candidate.participants_today, 10) / 10;

    // Soft preference for the format's course-length window.
    const [lo, hi] = format.preferredDistanceMeters;
    const formatFit = candidate.distance_meters >= lo && candidate.distance_meters <= hi
      ? 1
      : 0.4;

    const parts: Record<string, number> = {
      proximity: weights.proximity * proximity,
      quality: weights.quality * quality,
      freshness: weights.freshness * freshness,
      friendActivity: weights.friendActivity * friendActivity,
      participation: weights.participation * participation,
      formatFit: weights.formatFit * formatFit,
      rotation: 0.04 * rotationJitter(`${seed}:${candidate.course_id}`),
    };
    const score = Object.values(parts).reduce((total, v) => total + v, 0);
    return { candidate, score, parts };
  });

  return ranked.sort((a, b) =>
    b.score - a.score || a.candidate.course_id.localeCompare(b.candidate.course_id)
  );
}

/** Env override: CHALLENGE_WEIGHTS as JSON, e.g. {"proximity":0.4,...}. */
export function weightsFromEnv(
  env: (key: string) => string | undefined,
): RankingWeights {
  const raw = env("CHALLENGE_WEIGHTS");
  if (!raw) return DEFAULT_WEIGHTS;
  try {
    return { ...DEFAULT_WEIGHTS, ...JSON.parse(raw) };
  } catch {
    return DEFAULT_WEIGHTS;
  }
}

/** Radius ladder in km (directive §§2, 20). Env: CHALLENGE_RADII="10,25,50,100". */
export function radiiFromEnv(env: (key: string) => string | undefined): number[] {
  const raw = env("CHALLENGE_RADII");
  if (!raw) return [10, 25, 50, 100];
  const parsed = raw.split(",").map((s) => Number(s.trim())).filter((n) => n > 0);
  return parsed.length > 0 ? parsed : [10, 25, 50, 100];
}
