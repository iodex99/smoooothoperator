# App Store listing — v1.0

Everything App Store Connect asks for, written from what the app actually
does. Character limits are Apple's and are enforced by the form; the counts
in brackets are what the text below uses.

> Grounded in the shipped build: the four scoring weights are the live
> `configs/scoring/v1.json` values, the free allowance is
> `DailyRunAllowance.freeRunsPerDay`, and the Pro list is the paywall's own
> benefit rows. If any of those change, this file is wrong and should change
> with them.

---

## Name — 30 char limit

```
Smooooth Operator
```

[17] Four o's. It is the brand, it is the domain, and it is what the app
draws in its own header.

## Subtitle — 30 char limit

```
The smoothest drive wins
```

[24] Says the premise and pre-empts the reviewer's first worry: this is not
a speed game.

## Promotional text — 170 char limit, editable without review

```
Every road has a benchmark time. Match it smoothly and you score. Speed doesn't help — jerk, brake late or break the limit and you lose. 800+ real roads to drive.
```

[162] Editable any time without a new build, so use it for launches,
seasonal courses, or price changes.

---

## Description — 4000 char limit

```
Smooooth Operator turns the road you already drive into a course with a score.

Pick a route. Drive it. Get a score out of 10,000 that has almost nothing to do with how fast you went.

WHAT GETS SCORED

Four disciplines, weighted:

• Pace (35%) — every course has a benchmark time. Match it. Beating it does not help you.
• Smoothness (35%) — braking, acceleration, cornering. Every jerk costs you points.
• Control (20%) — consistency. Do you brake the same way twice?
• Legal (10%) — speed limit compliance. Exceed it and you lose points.

Fast alone doesn't win. A calm, deliberate driver beats an aggressive one on the same road, every time. That is the whole design, not a disclaimer.

800+ REAL ROADS

A curated catalogue of real routes — coast roads, canyon runs, city loops — each with a start gate, a finish gate and a benchmark. Find what's near you, or drive a road once and turn it into a course anyone can attempt.

RACE PEOPLE WHO AREN'T THERE

Every scored run leaves a ghost. Load a friend's ghost, or the course leader's, and watch the gap open and close in real time as you drive — a live delta in seconds, not a map full of dots. Ghosts share pace only. Nobody ever sees your raw location.

EVERY RUN IS VERIFIED

Your phone scores the run immediately, then the server rescores it authoritatively and checks the physics. Impossible drives never rank. Mock GPS and tampered sensors are detected. If a run can't be scored fairly — you crossed the start line already at speed, or GPS never locked — it tells you exactly why, in a sentence you can act on, instead of inventing a number.

LEADERBOARDS THAT MEAN SOMETHING

Global, country and friends-only boards, per course. A Smooooth Rating that only moves on verified runs. Wins and top-ten finishes counted honestly.

SHARE THE CARD

Finish a run and get a card: your route drawn as a glowing trace, your score, your four sub-scores, and a "beat it" link that opens the course for whoever you send it to.

FREE, AND ACTUALLY USABLE

Three fully scored runs every day, forever. No trial that expires, no feature that quietly stops working.

SMOOOOTH PRO

• Unlimited daily challenges
• Race any rival's ghost, on any course
• Make your own courses — drive a road once and it's on the map
• A garage — add every car you drive and see which is fastest on a road
• Support an independent app built by one driver

DRIVING SAFELY IS THE POINT

Mount your phone before you start. Never interact with the app while driving. Follow every traffic law. Speeding and aggressive driving lower your score — the app is built so that the safest line is also the winning one.

Location is used only during an active challenge, and only to time and score that run. Your precise route is never shown to other drivers.
```

[2,767] Leaves 1,233 characters of room for a localized line or a seasonal paragraph.

**Why the safety framing is load-bearing.** Guideline 1.1.7 and 4.2 get
applied hard to anything that looks like it rewards speed in a car. The
description says three separate times, in three different registers, that
speed does not help — and every one of those statements is true of the
scoring config. Do not trim them for length.

---

## Keywords — 100 char limit, comma separated, no spaces

```
driving,drive,road,route,smooth,score,leaderboard,ghost,car,scenic,commute,telemetry,gps,rally
```

[94] Deliberately excludes "racing", "speed" and "fast". Those terms invite
exactly the review scrutiny the description works to avoid, and they would
attract users this app will disappoint.

## What's New — v1.0

```
First release.

Drive a real road, get scored on smoothness rather than speed, and race the ghosts of people who drove it before you.
```

---

## App Review notes

Paste into *App Review Information → Notes*. The reviewer is at a desk and
cannot drive; an app whose core feature appears not to work gets rejected.

```
Smooooth Operator scores real driving using GPS and motion sensors, so the core loop requires being in a moving vehicle.

At a desk or as a passenger, the app will show courses, leaderboards, profiles and the paywall normally, but a challenge run cannot be scored — a stationary run is correctly reported as INELIGIBLE with the reason shown on screen, rather than being given a fabricated score. That is intended behaviour, not a failure.

To see a completed run without driving, use the demo account below, which has verified runs already attached:

  Email: <demo@…>
  Password: <…>

Safety: the app requires an explicit safety acknowledgement before the first run, does not reward speed (speed limit compliance is a scored component and exceeding the limit loses points), and shows a single large control during an active run.

Location: used only during an active challenge, for timing and scoring. Background location is requested because a run continues while the phone is locked and mounted. Precise routes are never shown to other users; shared "ghosts" contain pace only.
```

**Create the demo account before you submit** and leave verified runs on it.
A reviewer who sees only empty states has no way to evaluate the app.

---

## Support URLs

| Field | Value |
|---|---|
| Support URL | `https://smoooothoperator.com/support` |
| Marketing URL | `https://smoooothoperator.com` |
| Privacy Policy URL | `https://smoooothoperator.com/privacy` |

All three must resolve **before** you submit — Apple checks them during
review. See Phase 5 of `docs/LAUNCH.md`.
