# Launch runbook

> Everything between here and the App Store, in dependency order. Items marked
> **YOU** need an account, a card, or a physical device and cannot be done from
> this Codespace. Items marked **ME** I can do once the thing above it exists.

---

## Does the domain have to exist first?

**No — it is not a launch blocker.** Apple requires a *reachable* privacy policy
URL and support URL. They do not have to be on your own domain. A free
`smoooothoperator.pages.dev` from Cloudflare Pages satisfies Apple completely.

**But buy it now anyway**, for three reasons:

1. **Three things already point at it and will be dead until it resolves.** The
   share card footer reads `smoooothoperator.com`, the legal links in the
   paywall and About screen point there, and the universal-links entitlement
   declares `applinks:smoooothoperator.com`. A share card is designed to travel
   to strangers — a dead domain on it is worse than no domain.
2. **The support email has to work.** Apple rejects apps whose support address
   bounces, and `support@smoooothoperator.com` needs the domain to exist.
3. **It is ~$12/year and someone else can take it.** The name is distinctive
   enough to be worth squatting.

**If you want to launch before the domain resolves**, tell me and I will point
`Brand.domain` at the Pages subdomain — it is one constant now, so it is a
one-line change plus a CI build. Do not ship with the current value pointing at
nothing.

---

## Phase 0 — Accounts and money

Nothing else can start until these exist.

1. **YOU — Apple Developer Program, $99/year.** This gates *everything*: bundle
   identifiers, TestFlight, StoreKit products, Sign in with Apple, push, the
   lot. Enrolment as an individual is usually same-day; as a company it needs a
   D-U-N-S number and can take a week or more. Start here.
2. **YOU — buy `smoooothoperator.com`** (see above).
3. **YOU — decide the price** of Smooooth Pro weekly / monthly / yearly. You
   cannot skip this: the product records need real prices, and the analytics
   console shows `—` for MRR until it is told what they are.

---

## Phase 1 — Make the backend real

The Supabase project exists but is **empty** — I checked, and `public.courses`
does not exist there yet. All 34 migrations are still local-only.

4. **YOU — push the schema.** This needs the database password, which I
   deliberately do not have:

   ```bash
   supabase link --project-ref tsxyxgtjihycaoydyafp
   supabase db push
   supabase db seed         # loads the 397-course catalog
   ```

5. **YOU — turn on the auth providers.** I queried `/auth/v1/settings` and
   every provider is `false`, including Apple and Google. **Nobody can sign in
   right now, including you** — which also means the analytics console cannot be
   reached. Authentication → Providers → enable Apple and Google, then add
   `smooothoperator://auth-callback` to the redirect allow-list.
   (Three o's in that scheme is correct — it is what the app registers.)

6. **YOU — deploy the edge functions:**

   ```bash
   supabase functions deploy score-run today-challenge \
       validate-course resolve-challenge appstore-notifications delete-account
   ```

7. **YOU — set the one secret that is not automatic:**

   ```bash
   supabase secrets set APPLE_ROOT_CA_SHA256=<sha256 of Apple's root CA DER>
   ```

   Without it the App Store webhook returns **503 on purpose** — it refuses to
   process a payload it cannot verify. That is the correct behaviour, but it
   means subscriptions silently never activate until this is set.

8. **YOU — grant yourself operator access.** There is deliberately no way to do
   this from the browser:

   ```sql
   insert into public.admins (user_id)
   values ('<your auth.users id>');
   ```

9. **YOU — enter the real prices** so MRR stops reading `—`:

   ```sql
   update public.product_prices set price_minor = 499  -- $4.99
    where product_id = 'smooooth.pro.monthly';
   ```

---

## Phase 2 — App Store Connect

10. **YOU — create the app record.** Bundle ID must match `project.yml`.
11. **YOU — create three auto-renewable subscriptions** in one subscription
    group, with these exact identifiers — the app and the database both check
    them by string:
    - `smooooth.pro.weekly`
    - `smooooth.pro.monthly`
    - `smooooth.pro.yearly`
12. **YOU — set the App Store Server Notifications V2 URL** to
    `https://tsxyxgtjihycaoydyafp.supabase.co/functions/v1/appstore-notifications`
    and hit **Test**. It returns 200 for Apple's TEST notification specifically
    so this button works.
13. **YOU — fill in the privacy nutrition labels.** Declare: precise location
    (app functionality, linked to identity), motion/fitness data, and purchase
    history. `PrivacyInfo.xcprivacy` already declares the APIs; the nutrition
    label is a separate form and Apple checks they agree.
14. **YOU — screenshots and copy.** The CI gallery is a decent starting set.

---

## Phase 3 — The build

15. **ME — Team ID.** Send it and I will put it in the AASA file (currently
    the literal string `TEAMID`). Nothing else in the repo needs it: the build
    takes `DEVELOPMENT_TEAM` from a secret at build time.

16. **YOU — get it onto your iPhone. No Mac required.**

    **You do not need App Store publication to install on a phone**, and it is
    not the fastest route either. TestFlight installs a real signed build on a
    real device, and for **internal** testers Apple does not review it first —
    it appears minutes after processing.

    Archiving and signing need macOS, which is why this used to imply owning a
    Mac. It no longer does: `.github/workflows/testflight.yml` does the whole
    thing on the CI Mac. Add four secrets (the workflow header says where each
    comes from), press **Run workflow**, then install TestFlight on the iPhone
    and sign in with the same Apple ID.

    ```
    APPLE_TEAM_ID  APPSTORE_KEY_ID  APPSTORE_ISSUER_ID  APPSTORE_PRIVATE_KEY
    ```

    That workflow has never run and cannot be tested without a paid account.
    Expect the first attempt to want a small correction; send me the log.

    **Already proven, for free:** the nightly job now builds for a real device
    as well as the simulator, so the app is known to compile for arm64 against
    the device SDK. That was an entire class of failure sitting between us and
    the first drive, and it is closed without spending anything.

---

## Phase 4 — The step that actually decides whether this works

17. **YOU — drive one real course on a real iPhone.**

    **No sensor path in this project has ever seen a real GPS chip.** Every
    number, every test, every screenshot comes from a simulator feeding
    synthetic samples through the real pipeline. The engine is deterministic and
    heavily tested against those samples, but real GPS drifts, loses lock in
    tunnels, reports optimistic accuracy, and behaves differently on every
    handset.

    This single drive will teach you more than any further work I can do from
    here. Do it before TestFlight goes wide, and send me the run — I built the
    telemetry to be exportable exactly for this.

---

## Phase 5 — Web

18. **ME/YOU — deploy the site:**

    ```bash
    npx wrangler pages deploy web --project-name smoooothoperator
    ```

19. **YOU — point the domain** at the Pages project, then verify
    `https://smoooothoperator.com/.well-known/apple-app-site-association`
    returns `application/json` with **no redirect**. Universal links fail
    silently otherwise — there is no error to see anywhere.

20. **YOU — make `support@`, `privacy@` and `legal@smoooothoperator.com` reach
    a real inbox.** Cloudflare Email Routing does this free.

---

## Before you submit: what was still broken — all eight now fixed

Every item from the audit list, closed on 2026-08-14.

| # | Was | Now |
|---|---|---|
| 1 | `DriveSession` buffered motion data at 50 Hz until iOS killed the app | Three ceilings — idle, run length, sample count — and hitting one releases the buffers instead of holding them |
| 2 | A crash mid-drive destroyed the whole run | `InFlightRecorder` journals the drive to disk as it happens; a file torn mid-write still recovers everything before the tear |
| 3 | Racing your own run showed you ~2.6 s ahead of yourself | **0.31 s worst, under 0.06 s across the middle 80%.** It was three bugs, not one — see `docs/FAIRNESS.md` |
| 4 | Nothing measured stopped time | Measured, and a run stopped for >25% of its duration is flagged and not ranked — with a 20 s floor so one red light never counts |
| 5 | A shared challenge link opened the app and dropped the code | Parsed in the Kit, hostile input refused, wrong hosts refused |
| 6 | A run with no GPS showed ~6,500 and said "provisional" | An ineligible run shows a dash and says it cannot be scored |
| 7 | Zero accessibility modifiers; "End run" was a 34 pt target | Scaling text, 44 pt targets, VoiceOver labels, and `tools/a11y-check.sh` in `make test` so it cannot rot |
| 8 | Stale scoring jobs were reset forever and never re-driven | Attempts counted, exponential backoff, a loud failure after five, and the scorer actually re-invoked |

**What that leaves.** Nothing on this list blocks submission. The remaining
unknowns are not code:

- **The one real drive (step 17).** Still the largest. No sensor path here
  has ever seen a real GPS chip.
- **The `slowSmooth` test fixture** never reaches the finish gate, so the
  "slower driver falls behind" test stays disabled. That is a fixture
  limitation, not an engine defect — but it means the behaviour is unproven.
- **Gate radius asymmetry and multi-crossing gates** remain open in
  `docs/FAIRNESS.md`, both small next to what has been fixed.
- **Course creation has never met a real GPS chip either.** The builder is
  tested against simulated drives with noise, but the shape of a real trace
  — tunnels, urban canyons, a phone in a cupholder — is unknown. Create one
  course on the real drive in step 17 and check what comes out.

## What is already done

- Engine, scoring, anti-cheat, ghosts, leaderboards, friends — 321 Kit
  tests, deterministic, Swift ≡ TypeScript on 12 golden vectors.
- **Custom courses — a driver can now make one.** You create a course by
  driving it: record the road once, gates are placed at 0/25/50/75/100%, and
  the server re-validates every rule before it enters the catalog. Pro-gated
  in the app and re-checked on the server. The Swift→TypeScript contract is
  tested against output the Swift builder actually generates.
- Database: 34 migrations, RLS on every table, **346 pgTAP tests**.
- Server: 6 edge functions, 101 Deno tests, fail-closed App Store webhook.
- iOS: builds, boots and completes a scored ghost race on the CI Mac.
- Site: landing, privacy, terms, support, and the operator console.
- Owner analytics: users, paying, MRR/ARR, catalog by region, top courses,
  activity by region, 30-day growth, retention — all refused to non-operators.
