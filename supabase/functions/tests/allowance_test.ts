import { assertEquals } from "jsr:@std/assert@1";
import {
  COURSES_PER_DAY,
  FREE_RUNS_PER_DAY,
  utcDayStart,
  withinAllowance,
  withinCourseAllowance,
} from "../_shared/allowance.ts";

Deno.test("the free tier stops at the documented number", () => {
  assertEquals(FREE_RUNS_PER_DAY, 3, "must match the Kit's DailyRunAllowance");
  assertEquals(withinAllowance(0, false), true);
  assertEquals(withinAllowance(2, false), true);
  assertEquals(withinAllowance(3, false), false);
});

Deno.test("Pro has no ceiling", () => {
  assertEquals(withinAllowance(999, true), true);
});

Deno.test("the day boundary is UTC, not a client-supplied timezone", () => {
  // A paid boundary must not accept an input the client controls — a device
  // clock or timezone could otherwise reset the allowance at will.
  const start = utcDayStart(new Date("2026-08-13T23:59:59Z"));
  assertEquals(start, "2026-08-13T00:00:00.000Z");
  assertEquals(
    utcDayStart(new Date("2026-08-14T00:00:01Z")),
    "2026-08-14T00:00:00.000Z",
  );
});

Deno.test("course creation has a daily ceiling too", () => {
  // Course creation was gated on Pro and nothing else, so one $4.99
  // subscription could insert unbounded rows into the catalog every driver
  // browses — the same table the browse work went to some trouble to stop
  // scanning.
  assertEquals(COURSES_PER_DAY, 10);
  assertEquals(withinCourseAllowance(0), true);
  assertEquals(withinCourseAllowance(9), true);
  assertEquals(withinCourseAllowance(10), false);
  assertEquals(withinCourseAllowance(9999), false);
});

Deno.test("the course ceiling is not a paywall — Pro already paid for it", () => {
  // withinCourseAllowance takes no `isPro`, and that is the point: this
  // limit says how FAST, not whether. Adding an isPro escape would make it
  // a second paywall on a feature already bought.
  assertEquals(withinCourseAllowance.length, 1);
});
