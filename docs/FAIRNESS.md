# Are two drivers on the same road running the same race?

> Living document. Pace is 35% of the score and is measured between two
> gates on a public road, which is a much weaker guarantee of fairness than
> it looks. This is the catalogue of ways it can be unequal, what the app
> does about each, and what it deliberately does not.

The governing principle: **when a run cannot be compared fairly, it is kept,
scored and shown to the driver — and ranked nowhere.** That is the same
treatment a questionable run gets, and it accuses nobody. Refusing to record
a drive someone actually did is never the answer.

---

## Handled

### 1. The flying start — **fixed 2026-08-13**
A driver arriving at the start gate at 100 km/h with a mile of run-up banks
seconds no amount of skill can answer; a driver launching from the line pays
for every one of them. Entry speed was completely unbounded.

**Now:** entry speed at the start gate is measured and compared against
`maxStartEntrySpeedMps` (8 m/s ≈ 29 km/h — a slow roll-up, achievable where
stopping is not). Above it, the run is flagged `flyingStart` at *warning*
severity: scored, shown, never ranked. The rule is stated on the READY
screen **before** the clock exists, and explained on the result screen after
— a fairness rule a driver only discovers afterwards is a trap.

Implemented in the Swift reference *and* the TypeScript port in one commit,
because golden vectors compare integrity flags: a check on one side only
breaks the determinism contract. 14 tests, 7 per side, asserting the same
boundaries and the same evidence string.

### 2. Staging on the line
Sitting inside the start gate before launching must not burn clock. The
ghost clock and the live clock both start at the first *moving* fix after
the gate is hit, not at the gate hit itself.

### 3. Starting mid-course
A driver who opens the app already past the start gate never triggers gate 0,
so the run never starts rather than recording a partial course as a whole
one. The gate tracker only ever looks for the *next* gate in sequence, so a
road that loops back through an earlier gate cannot re-trigger it either.

### 4. Gates too close together
`CourseValidator.checkpointsTooClose` refuses a course whose gates overlap,
which would otherwise make "which gate did I just cross" ambiguous.

---

## Identified, NOT yet handled — ranked by how much unfairness they cause

> The two biggest entries here — traffic and the ghost clock — were both
> closed on 2026-08-14 and are kept below with what the fix was.

### 4. Traffic, and stopping mid-run — **fixed 2026-08-14**
This was the largest gap in the document: a driver who caught three red
lights was scored against one who caught none, on a score that is 35% pace.

**Now:** stopped time is measured (`RunIntegrityEngine.stoppedSeconds`) and
a run stopped for more than **25% of its duration** is flagged
`heavilyInterrupted` at *warning* severity — kept, scored, shown, ranked
nowhere. The result screen says so in the driver's own terms: *"That's
traffic, not driving."*

Three deliberate choices:

- **An absolute floor of 20 s** sits under the fraction. On a short course a
  single red light can exceed 25% while being completely ordinary driving,
  and an accusation-shaped label for one junction would teach drivers to run
  them. That is the opposite of what this app is for.
- **Gaps are not stops.** A lost signal in a tunnel has no speed either, but
  it is `suspiciousGap`'s business, not this rule's.
- **Stopped time is NOT excluded from the clock.** That was the tempting
  option and it is the wrong one: it would reward stopping — a driver could
  pause to reset a bad segment — and it would stop measuring the thing the
  score claims to measure.

Implemented in the Swift reference and the TypeScript port in one commit
with byte-identical evidence strings, because golden vectors compare
integrity findings. 16 tests, 8 per side.

### B. ~~The ghost clock defect~~ — **fixed 2026-08-14**
Racing your own identical run used to show you **~2.6 s ahead of yourself**
(measured: mean −2.58 s, worst −2.71 s over a 194 s ghost). Worst is now
**0.31 s**, and across the middle 80% of a run it is **under 0.06 s**.

It turned out to be three bugs wearing one costume, and each had to be found
by measuring rather than reasoning:

1. **The anchors were different signals.** The live clock started on the
   first *raw* sample whose device-reported speed cleared a threshold; the
   ghost clock started on the first *processed* point whose *derived* speed
   cleared it. Filtered derivatives lag. Both sides now use
   `GhostEngine.startTime`, which anchors on **displacement** from the start
   gate — five metres, a quantity smoothing does not systematically delay.
   Gate hit, start, finish and duration now agree to **0.0 s**.
2. **The live origin was captured late.** A car can cross the start gate
   while the orientation estimator is still converging, so the session was
   still `.calibrating` and took its origin wherever it happened to be when
   `.ready` arrived — 13.5 m down the road. The origin is now looked up at
   the gate crossing itself.
3. **Both ends of the ghost were fictional.** The first point was pinned to
   `(progress: 0, elapsed: 0)` and the last to `progress: 1`. Neither is
   true: the clock starts once the car has moved five metres, and a run ends
   on *entering* the finish-gate circle at ~0.986. Those two lies stretched
   the ghost's first and last segments across ground the driver never
   covers, which is where the remaining seconds lived — the final tenth of
   the course alone was 1.83 s.

`GhostRaceTests.racingYourselfIsNeutral` is enabled and asserts < 0.5 s. Do
not relax that bound; it means the clocks have drifted apart again.

### C. Gate radius asymmetry
Gates are circles (40–45 m). Clipping the near edge and clipping the far
edge are not the same distance, so two identical drives can differ by the
gate diameter at each end. Small on a 5 km course, not small on a 1 km one.

### D. Gates a road passes through more than once
The catalog audit found 53 gates where the road re-enters the circle
(hairpins — Lysevegen's gate 1 is crossed **nine times**). Sequential
matching means the *first* crossing wins, which is usually right and
occasionally isn't.

### E. The slow-driver start condition
The `slowSmooth` simulator profile never triggers the live start condition
at all ("sensor stream ended before the run started"). If that reflects real
device behaviour rather than a simulator artefact, genuinely slow drivers
cannot record runs. Needs one real slow drive to settle before the threshold
is touched. Covered by a disabled test.

### F. Vehicle differences — deliberately NOT equalised
A driver in a fast car will out-pace the same driver in a slow one, and the
garage now records which car drove each run. That is *not* treated as
unfairness: the score rewards smoothness, control and legality alongside
pace, and the product's answer to "my car is slower" is to compare your own
cars to each other (`my_vehicle_bests`) and to drive better. Per-class
leaderboards are a plausible future feature, not a correctness fix.

### G. Conditions we cannot observe
Weather, time of day, road surface, passengers, tyre choice. A public-road
competition cannot control these. The honest position is that the benchmark
is a *reference*, not a level playing field, and that smoothness and control
— which dominate the score — are far less condition-sensitive than pace.

---

## Why not just require a full standing stop?

Because on many real roads you cannot legally or safely stop at the start
line, and a rule drivers must break to comply with is worse than a slightly
loose one. 8 m/s bounds the advantage to something small relative to a
multi-kilometre course while staying achievable. It is a config value, and
if real-device data shows it is wrong, it moves — on both sides, in one
commit.
