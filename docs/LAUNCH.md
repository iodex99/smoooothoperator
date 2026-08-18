# Launch runbook

> Everything between here and the App Store, in dependency order. Items marked
> **YOU** need an account, a card, or a physical device and cannot be done from
> this Codespace. Items marked **ME** I can do once the thing above it exists.

**Status 2026-08-18:** the Apple Developer Program and the domain are bought,
and the prices are decided. That clears Phase 0 entirely and unblocks
everything except the two things only a physical iPhone can settle.

## The one thing I am waiting on

**Your Apple Team ID** — ten characters, like `A1B2C3D4E5`. Find it at
[developer.apple.com/account](https://developer.apple.com/account) →
**Membership details** → *Team ID*.

It is not a secret (it appears in every app's receipt) and it is the only
value I cannot derive. One file needs it: `web/.well-known/apple-app-site-association`
currently contains the literal string `TEAMID`, and until it is replaced,
**shared challenge links will silently not open the app.** There is no error
anywhere when this is wrong — the link just opens Safari instead. Send it and
I will commit the change in a minute.

Everything else in this runbook you can start now.

---

## Phase 0 — Accounts and money — ✅ done

1. ~~Apple Developer Program, $99/year.~~ **Bought 2026-08-18.**
2. ~~Buy the domain.~~ **Bought 2026-08-18.**
3. ~~Decide the price.~~ **Decided 2026-08-18:**

   | Product id | Price | Period |
   |---|---|---|
   | `smooooth.pro.weekly` | **$7** | 1 week |
   | `smooooth.pro.monthly` | **$19** | 1 month |
   | `smooooth.pro.yearly` | **$99** | 1 year |

   Already done on my side: migration `0036` mirrors these into
   `product_prices` so MRR and ARR report real numbers instead of `—`, and
   `App/Configs/Products.storekit` matches so simulator and sandbox runs show
   the real ladder.

   **The app never reads either of those.** The paywall shows
   `product.displayPrice` straight from StoreKit, in the driver's own
   currency, so App Store Connect is the only source of truth for what anyone
   is actually charged. The mirror exists solely for your revenue figures —
   which means it can be wrong quietly. If App Store Connect does not offer
   exactly $7.00 / $19.00 / $99.00 and you take a neighbouring price point,
   **tell me the values you picked** and I will correct migration 0036.

---

## Phase 0b — The Apple Developer portal (do this first)

Now that the membership exists, these identifiers have to be created before
sign-in or the build will work. About twenty minutes, all at
[developer.apple.com/account](https://developer.apple.com/account).

3a. **YOU — send me your Team ID.** *Membership details* → *Team ID*. See the
    top of this file for why.

3b. **YOU — register the App ID.** *Identifiers* → **+** → *App IDs* → *App*.
    - Description: Smooooth Operator
    - Bundle ID: **Explicit**, `app.smooooth.operator`
    - Capabilities — tick these three, they are all in the entitlements file:
      **Sign in with Apple**, **Associated Domains**, **Push Notifications**.

    (Push is ticked now because adding a capability later invalidates the
    provisioning profile and means a rebuild. The app ships no remote-push
    code yet — `DriverNotifications` is local-only until APNs is wired — so
    nothing depends on it working.)

3c. **YOU — create a Services ID** (this is what Supabase uses for Sign in
    with Apple, and it is *not* the same thing as the App ID).
    *Identifiers* → **+** → *Services IDs*.
    - Identifier: `app.smooooth.operator.signin`
    - Enable *Sign in with Apple* → **Configure**:
      - Primary App ID: `app.smooooth.operator`
      - Domains: `smoooothoperator.com`
      - Return URL: `https://tsxyxgtjihycaoydyafp.supabase.co/auth/v1/callback`

3d. **YOU — create a Sign in with Apple key.** *Keys* → **+** → name it,
    tick **Sign in with Apple**, configure it to the primary App ID, then
    **Download the `.p8` file**.

    **You can only download it once.** Keep it somewhere safe. Note the
    **Key ID** shown next to it — you need Key ID, Team ID, the Services ID
    and the `.p8` contents for Phase 1 step 5.

3e. **YOU — create an App Store Connect API key**, for the TestFlight
    workflow. This one lives in *App Store Connect*, not the developer
    portal: [appstoreconnect.apple.com](https://appstoreconnect.apple.com) →
    *Users and Access* → *Integrations* → *App Store Connect API* → **+**.
    - Access: **App Manager**
    - Download the `.p8` (again, once only) and note the **Key ID** and the
      **Issuer ID** shown above the table.

    These become three of the four GitHub secrets in Phase 3.

---

## Phase 1 — Make the backend real

The Supabase project exists but is **empty** — I checked, and `public.courses`
does not exist there yet. All 36 migrations are still local-only.

4. **YOU — push the schema.** This needs the database password, which I
   deliberately do not have:

   ```bash
   supabase link --project-ref tsxyxgtjihycaoydyafp
   supabase db push
   supabase db seed         # loads the 803-course catalog
   ```

5. **YOU — turn on the auth providers.** Every provider is currently `false`,
   including Apple and Google. **Nobody can sign in right now, including you**
   — which also means the operator console cannot be reached.

   Supabase dashboard → *Authentication* → *Providers* → **Apple** → enable,
   then fill in the four values from Phase 0b:

   | Field | What goes in it |
   |---|---|
   | Client IDs | `app.smooooth.operator.signin` (the **Services** ID) |
   | Secret Key | the entire contents of the `.p8` file from 3d |
   | Team ID | your Team ID |
   | Key ID | the Key ID from 3d |

   **Google** is optional and free: create an OAuth client (type: *Web
   application*) in the Google Cloud console with the same
   `https://tsxyxgtjihycaoydyafp.supabase.co/auth/v1/callback` redirect, and
   paste the client id and secret.

   Then *Authentication* → *URL Configuration* → **Redirect URLs** → add
   `smooothoperator://auth-callback`. Sign-in silently fails without it — the
   callback is how the app receives the session. (Three o's in that scheme is
   correct; it is what the app registers, and it is deliberately not the same
   as the four-o brand name.)

6. **YOU — deploy the edge functions:**

   ```bash
   supabase functions deploy score-run today-challenge \
       validate-course resolve-challenge appstore-notifications \
       delete-account purge-telemetry
   ```

   `purge-telemetry` is the retention job. It is driven by pg_cron, which
   needs two database settings that only exist in production — without them
   it returns 0 rather than erroring nightly forever:

   ```sql
   alter database postgres set app.functions_url = 'https://<ref>.supabase.co/functions/v1';
   alter database postgres set app.service_role_key = '<service role key>';
   ```

   The same two settings drive the scoring sweeper, so if scoring works,
   retention works.

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

Also do this early: the **Paid Applications agreement** in step 10a can take
days to clear, and until it does Apple will not take money from anyone.

10. **YOU — create the app record.** *My Apps* → **+** → *New App*.
    - Platform: iOS
    - Bundle ID: **`app.smooooth.operator`** — it must match exactly; it is
      set in `App/project.yml` and baked into the entitlements.
    - SKU: anything you like, `smooooth-operator` is fine. It is internal.
    - Primary language, and the app name as it appears on the store.

10a. **YOU — sign the Paid Applications agreement.** *Business* → *Agreements*
     → complete **banking details and tax forms**. This is the slowest item in
     the whole runbook: it can take several days and sometimes needs
     documents. Nothing sells until it is active, so start it the same day.

11. **YOU — create the three subscriptions.** *Subscriptions* → create **one
    subscription group** (name it something like "Smooooth Pro" — the group
    name is visible to users), then add three auto-renewable subscriptions
    inside it. The identifiers must be exact; the app and the database both
    match them by string:

    | Product ID | Duration | Price |
    |---|---|---|
    | `smooooth.pro.weekly` | 1 week | **$7** |
    | `smooooth.pro.monthly` | 1 month | **$19** |
    | `smooooth.pro.yearly` | 1 year | **$99** |

    Each one needs a display name and a description before it can be
    submitted, and at least one needs a **subscription group display name**.

    **If Apple does not offer exactly $7.00 / $19.00 / $99.00**, take the
    nearest price point and tell me the three values — migration `0036`
    mirrors them for revenue reporting and would otherwise be quietly wrong.

12. **YOU — set the App Store Server Notifications V2 URL.** *App Information*
    → *App Store Server Notifications* → **Production Server URL**:

    ```
    https://tsxyxgtjihycaoydyafp.supabase.co/functions/v1/appstore-notifications
    ```

    Set the sandbox URL to the same value. Then press **Test**. It returns 200
    for Apple's TEST notification specifically so that button works — but only
    after Phase 1 step 7, because without `APPLE_ROOT_CA_SHA256` the function
    returns 503 by design and the test will fail.

13. **YOU — fill in the privacy nutrition labels.** *App Privacy*. Declare:
    **precise location** (app functionality, linked to identity), **motion and
    fitness data**, and **purchase history**. `PrivacyInfo.xcprivacy` already
    declares the underlying APIs; the nutrition label is a separate form and
    Apple checks the two agree.

14. **YOU — screenshots and copy.** The CI gallery artifact is a decent
    starting set — download it from the latest *iOS nightly build* run. You
    need 6.7" and 6.5" sizes at minimum.

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
    thing on the CI Mac. Add **six** repository secrets — GitHub → *Settings*
    → *Secrets and variables* → *Actions* → *New repository secret* — then
    press **Run workflow** on the TestFlight action, and install TestFlight on
    the iPhone signed in with the same Apple ID.

    | Secret | Where it comes from |
    |---|---|
    | `APPLE_TEAM_ID` | Phase 0b step 3a |
    | `APPSTORE_KEY_ID` | Phase 0b step 3e |
    | `APPSTORE_ISSUER_ID` | Phase 0b step 3e |
    | `APPSTORE_PRIVATE_KEY` | the **entire** `.p8` from 3e, `-----BEGIN` lines included |
    | `SUPABASE_URL` | `https://tsxyxgtjihycaoydyafp.supabase.co` |
    | `SUPABASE_ANON_KEY` | Supabase → *Settings* → *API* → publishable key |

    **The last two were missing until 2026-08-18 and would have cost you a
    build.** `project.yml` reads them from a gitignored xcconfig; the nightly
    job writes placeholders because it only needs to prove the code compiles,
    and the TestFlight job wrote nothing at all. The build would have
    succeeded and produced an app that installs, launches, and cannot reach
    the backend — no sign-in, no courses, no uploads, and nothing on screen
    to say why.

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

## Phase 5 — The domain and the site (Cloudflare)

**Do this early, not last.** App Store review requires a *reachable* privacy
policy and support URL, and Apple checks them during review — a domain that
resolves the day after you submit is a rejection. Everything here is free
apart from the domain you already own.

**Where you bought the domain decides step 18.** If you registered it *at*
Cloudflare, DNS is already there and you can skip straight to 19.

18. **YOU — put the domain on Cloudflare.**
    [dash.cloudflare.com](https://dash.cloudflare.com) → *Add a site* → type
    the domain → **Free** plan. Cloudflare shows you two nameservers. Go to
    wherever you bought the domain (Namecheap, GoDaddy, Porkbun…), find
    *Nameservers*, replace what is there with Cloudflare's two, and save.
    Propagation is usually minutes; Cloudflare emails you when it is active.

19. **YOU — create the Pages project.** Cloudflare dashboard →
    *Workers & Pages* → *Create* → *Pages* → **Upload assets** (not the Git
    option — this repository is private and does not need to be connected).
    Name it `smoooothoperator`. It will ask for files; you need the built
    `web/` directory, which is what step 20 produces.

    Or skip the dashboard entirely and do it from here in one command —
    tell me and I will run it, or run it yourself:

    ```bash
    npx wrangler pages deploy web --project-name smoooothoperator
    ```

    Wrangler opens a browser window once to authorise. The site is four
    static pages plus the AASA file; there is no build step.

20. **YOU — attach the domain to the Pages project.** In the Pages project →
    *Custom domains* → *Set up a custom domain* → enter the apex domain
    (`smoooothoperator.com`, no `www`). Cloudflare adds the DNS record
    itself. Add `www` as a second custom domain if you want it to work too.

21. **YOU — verify the AASA file, because nothing tells you when it is wrong.**

    ```bash
    curl -sI https://smoooothoperator.com/.well-known/apple-app-site-association
    ```

    Three things must be true, and all three are silent failures:
    - **HTTP 200 with no redirect.** Apple does not follow redirects for this
      file. A `301` from apex to `www` breaks universal links completely.
    - **`content-type: application/json`.** Not `text/plain`, not
      `application/octet-stream`.
    - **The body contains your real Team ID**, not the string `TEAMID`.

    If all three hold, a shared challenge link opens the app. If any fails,
    it opens Safari and nobody ever finds out why.

22. **YOU — make the email addresses work.** Cloudflare dashboard → *Email* →
    *Email Routing* → *Get started*. Add three routes, all forwarding to your
    real inbox:

    | Address | Why |
    |---|---|
    | `support@` | **Apple rejects apps whose support address bounces.** Linked from Profile. |
    | `privacy@` | Named in the privacy policy as the data-request address. |
    | `legal@` | Named in the terms. |

    Cloudflare sends a confirmation email to your destination address; click
    the link or nothing forwards. Verify by sending yourself a message to
    `support@smoooothoperator.com` and watching it arrive.

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

- Engine, scoring, anti-cheat, ghosts, leaderboards, friends — 366 Kit
  tests, deterministic, Swift ≡ TypeScript on 12 golden vectors.
- **803 courses across 51 countries**, every one routed over real
  OpenStreetMap roads rather than authored by hand.
- **Notifications, with the driving rule first** — nothing is delivered to
  someone who is currently driving, whatever else is true.
- **Telemetry is 6.7× smaller and no longer kept forever.** Blobs are
  gzipped and written at sensor resolution, and deleted 90 days after a run
  is scored. That was the difference between a negligible storage bill and
  ~$800/month at 100,000 users.
- **Custom courses — a driver can now make one.** You create a course by
  driving it: record the road once, gates are placed at 0/25/50/75/100%, and
  the server re-validates every rule before it enters the catalog. Pro-gated
  in the app and re-checked on the server. The Swift→TypeScript contract is
  tested against output the Swift builder actually generates.
- Database: 35 migrations, RLS on every table, **360 pgTAP tests**.
- Server: 7 edge functions, 114 Deno tests, fail-closed App Store webhook.
- iOS: builds, boots and completes a scored ghost race on the CI Mac.
- Site: landing, privacy, terms, support, and the operator console.
- Owner analytics: users, paying, MRR/ARR, catalog by region, top courses,
  activity by region, 30-day growth, retention — all refused to non-operators.
