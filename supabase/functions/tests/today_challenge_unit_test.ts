// Unit tests for the Today's Challenge pure logic: local-date resolution,
// deterministic ranking, rotation, honesty rules, and config parsing.
// No network, no stack — these always run.

import {
  assert,
  assertEquals,
  assertNotEquals,
} from "jsr:@std/assert@1";
import { localDate, localDayStart } from "../_shared/challenge/localdate.ts";
import { activeFormat, FORMATS } from "../_shared/challenge/formats.ts";
import {
  type Candidate,
  DEFAULT_WEIGHTS,
  radiiFromEnv,
  rankCandidates,
  rotationJitter,
  weightsFromEnv,
} from "../_shared/challenge/ranking.ts";

const noEnv = (_: string) => undefined;

function candidate(overrides: Partial<Candidate>): Candidate {
  return {
    course_id: crypto.randomUUID(),
    name: "Course",
    proximity_km: 5,
    distance_meters: 8000,
    estimated_duration_seconds: 900,
    difficulty: 3,
    turn_count: 12,
    benchmark_seconds: 600,
    verified_drivers: 5,
    days_since_user_drove: null,
    days_since_assigned: null,
    friend_best_score: null,
    friend_username: null,
    friend_days_ago: null,
    participants_today: 0,
    your_best: null,
    ...overrides,
  };
}

// ── Local date (directive §16) ──────────────────────────────────────────────

Deno.test("localDate: London and LA are on different days at 00:30 UTC", () => {
  const instant = new Date("2026-08-13T00:30:00Z");
  assertEquals(localDate("Europe/London", null, instant), "2026-08-13");
  assertEquals(localDate("America/Los_Angeles", null, instant), "2026-08-12");
});

Deno.test("localDate: longitude fallback approximates the timezone", () => {
  const instant = new Date("2026-08-13T00:30:00Z");
  // LA is ~-118° → -8h → still Aug 12 locally.
  assertEquals(localDate(null, -118.5, instant), "2026-08-12");
  // Mumbai ~73° → +5h → Aug 13.
  assertEquals(localDate(null, 72.9, instant), "2026-08-13");
});

Deno.test("localDate: garbage timezone falls back gracefully", () => {
  const instant = new Date("2026-08-13T12:00:00Z");
  assertEquals(localDate("Not/AZone", -118.5, instant), "2026-08-13");
});

Deno.test("localDayStart: participants window starts at the local midnight", () => {
  const instant = new Date("2026-08-13T18:00:00Z");
  const start = localDayStart("America/Los_Angeles", null, instant);
  // LA midnight Aug 13 PDT = 07:00 UTC.
  assertEquals(start.toISOString(), "2026-08-13T07:00:00.000Z");
});

// ── Ranking (directive §§4-5, 14) ───────────────────────────────────────────

Deno.test("ranking is deterministic for the same seed", () => {
  const candidates = [
    candidate({ course_id: "00000000-0000-0000-0000-000000000001" }),
    candidate({ course_id: "00000000-0000-0000-0000-000000000002" }),
  ];
  const a = rankCandidates(candidates, FORMATS.SMOOTH_SPRINT, "user:2026-08-13");
  const b = rankCandidates(candidates, FORMATS.SMOOTH_SPRINT, "user:2026-08-13");
  assertEquals(a[0].candidate.course_id, b[0].candidate.course_id);
  assertEquals(a[0].score, b[0].score);
});

Deno.test("rotation: the course driven yesterday loses to an equal fresh course", () => {
  const driven = candidate({
    course_id: "00000000-0000-0000-0000-00000000000a",
    days_since_user_drove: 1,
  });
  const fresh = candidate({ course_id: "00000000-0000-0000-0000-00000000000b" });
  const ranked = rankCandidates([driven, fresh], FORMATS.SMOOTH_SPRINT, "u:d");
  assertEquals(ranked[0].candidate.course_id, fresh.course_id);
});

Deno.test("rotation: recently ASSIGNED (shown, not driven) also decays", () => {
  const shown = candidate({
    course_id: "00000000-0000-0000-0000-00000000000a",
    days_since_assigned: 1,
  });
  const fresh = candidate({ course_id: "00000000-0000-0000-0000-00000000000b" });
  const ranked = rankCandidates([shown, fresh], FORMATS.SMOOTH_SPRINT, "u:d");
  assertEquals(ranked[0].candidate.course_id, fresh.course_id);
});

Deno.test("low density: the only course wins even if driven yesterday", () => {
  const only = candidate({ days_since_user_drove: 1 });
  const ranked = rankCandidates([only], FORMATS.SMOOTH_SPRINT, "u:d");
  assertEquals(ranked.length, 1);
  assertEquals(ranked[0].candidate.course_id, only.course_id);
});

Deno.test("friend activity this week boosts a course past an equal rival", () => {
  const withFriend = candidate({
    course_id: "00000000-0000-0000-0000-00000000000a",
    friend_best_score: 9100,
    friend_username: "david",
    friend_days_ago: 1,
  });
  const without = candidate({ course_id: "00000000-0000-0000-0000-00000000000b" });
  const ranked = rankCandidates([withFriend, without], FORMATS.SMOOTH_SPRINT, "u:d");
  assertEquals(ranked[0].candidate.course_id, withFriend.course_id);
});

Deno.test("nearest is not automatically best (directive §14)", () => {
  const near = candidate({
    course_id: "00000000-0000-0000-0000-00000000000a",
    proximity_km: 1,
    days_since_user_drove: 1, // stale
    verified_drivers: 0,
    benchmark_seconds: null,
    turn_count: 2,
  });
  const better = candidate({
    course_id: "00000000-0000-0000-0000-00000000000b",
    proximity_km: 12,
    verified_drivers: 15,
  });
  const ranked = rankCandidates([near, better], FORMATS.SMOOTH_SPRINT, "u:d");
  assertEquals(ranked[0].candidate.course_id, better.course_id);
});

Deno.test("honesty: zero participants stays zero — nothing is fabricated", () => {
  const ranked = rankCandidates(
    [candidate({ participants_today: 0 })],
    FORMATS.SMOOTH_SPRINT,
    "u:d",
  );
  assertEquals(ranked[0].parts.participation, 0);
  assertEquals(ranked[0].candidate.participants_today, 0);
});

Deno.test("rotation jitter is tiny, bounded, and seed-stable", () => {
  const a = rotationJitter("user:2026-08-13:course");
  const b = rotationJitter("user:2026-08-13:course");
  const c = rotationJitter("user:2026-08-14:course");
  assertEquals(a, b);
  assertNotEquals(a, c);
  assert(a >= 0 && a < 1);
});

Deno.test("format fit prefers the sprint window without excluding outliers", () => {
  const short = candidate({
    course_id: "00000000-0000-0000-0000-00000000000a",
    distance_meters: 1200,
  });
  const inWindow = candidate({
    course_id: "00000000-0000-0000-0000-00000000000b",
    distance_meters: 9000,
  });
  const ranked = rankCandidates([short, inWindow], FORMATS.SMOOTH_SPRINT, "u:d");
  assertEquals(ranked[0].candidate.course_id, inWindow.course_id);
  assertEquals(ranked.length, 2); // the outlier is deprioritized, never dropped
});

// ── Config (directive §§2, 14, 15) ──────────────────────────────────────────

Deno.test("format registry: default is SMOOTH_SPRINT; env overrides", () => {
  assertEquals(activeFormat(noEnv).key, "SMOOTH_SPRINT");
  assertEquals(
    activeFormat((k) => k === "CHALLENGE_FORMAT" ? "SMOOTH_SPRINT" : undefined).key,
    "SMOOTH_SPRINT",
  );
  // Unknown format falls back instead of crashing the daily challenge.
  assertEquals(
    activeFormat((k) => k === "CHALLENGE_FORMAT" ? "NOT_A_FORMAT" : undefined).key,
    "SMOOTH_SPRINT",
  );
});

Deno.test("radius ladder: defaults and env override", () => {
  assertEquals(radiiFromEnv(noEnv), [10, 25, 50, 100]);
  assertEquals(
    radiiFromEnv((k) => k === "CHALLENGE_RADII" ? "5, 15, 40" : undefined),
    [5, 15, 40],
  );
  assertEquals(
    radiiFromEnv((k) => k === "CHALLENGE_RADII" ? "garbage" : undefined),
    [10, 25, 50, 100],
  );
});

Deno.test("weights: env merge keeps unspecified defaults", () => {
  const weights = weightsFromEnv((k) =>
    k === "CHALLENGE_WEIGHTS" ? '{"proximity": 0.5}' : undefined
  );
  assertEquals(weights.proximity, 0.5);
  assertEquals(weights.quality, DEFAULT_WEIGHTS.quality);
  assertEquals(weightsFromEnv(noEnv), DEFAULT_WEIGHTS);
});
