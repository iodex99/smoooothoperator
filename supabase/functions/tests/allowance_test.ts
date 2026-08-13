import { assertEquals } from "jsr:@std/assert@1";
import {
  FREE_RUNS_PER_DAY,
  utcDayStart,
  withinAllowance,
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
