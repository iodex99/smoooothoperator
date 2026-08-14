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
does not exist there yet. All 19 migrations are still local-only.

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
       validate-course resolve-challenge appstore-notifications
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

15. **ME — Team ID.** Send it and I will put it in `project.yml`, the
    entitlements and the AASA file (currently the literal string `TEAMID`).
16. **YOU or CI — archive and upload to TestFlight.** The CI Mac already builds
    and boots the app; it is not currently signing or uploading. I can add that
    once a Team ID and signing certificate exist.

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

## Before you submit: what is still genuinely broken

Ordered by how likely each is to bite a real user. The first two are the ones I
would fix before letting anyone else drive with this.

| # | Issue | Why it matters |
|---|---|---|
| 1 | **`DriveSession` has no timeout or sample cap.** | Left parked on the ready screen it accumulates IMU at 50 Hz — roughly **150 MB/hour** — until iOS kills the app. A driver who opens the app and then takes a phone call hits this. |
| 2 | **No crash-safe in-flight recorder.** | The upload queue protects a *finished* run. A crash mid-drive still loses the whole thing. |
| 3 | **Ghost clock anchor, ~2.6 s.** | Racing your own best run shows you permanently ~2.6 s ahead of yourself. The live clock and the ghost clock start on different signals. Measured, documented, and covered by a disabled test — see `docs/FAIRNESS.md`. |
| 4 | **Traffic and stopped time.** | The largest *fairness* gap. A driver who catches three red lights is compared against one who caught none, on a pace score. Nothing measures stopped time yet. |
| 5 | **Universal links declared but not handled.** | A shared challenge link opens the app and drops the code. |
| 6 | **Degenerate runs show flattering provisional scores.** | A run with no GPS shows ~6,500 before the server marks it invalid. It cannot rank, but the number shown is misleading. |
| 7 | **Zero accessibility modifiers.** | 23 fixed font sizes ignore Dynamic Type; some tap targets are under 44 pt, including **End run**, which is used in a car. |
| 8 | **Stale scoring jobs are never re-driven.** | The sweeper flips `processing → pending` but nothing re-invokes `score-run`. |

None of these block a TestFlight build. **1, 2 and 7 should be fixed before the
App Store**, and 7 is the kind of thing App Review sometimes rejects on.

---

## What is already done

- Engine, scoring, anti-cheat, ghosts, leaderboards, friends, custom courses —
  272 Kit tests, deterministic, Swift ≡ TypeScript on 12 golden vectors.
- Database: 19 migrations, RLS on every table, **223 pgTAP tests**.
- Server: 5 edge functions, 66 Deno tests, fail-closed App Store webhook.
- iOS: builds, boots and completes a scored ghost race on the CI Mac.
- Site: landing, privacy, terms, support, and the operator console.
- Owner analytics: users, paying, MRR/ARR, catalog by region, top courses,
  activity by region, 30-day growth, retention — all refused to non-operators.
