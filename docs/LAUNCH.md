# Launch runbook

> Everything between here and the App Store, in dependency order. Items marked
> **YOU** need an account, a card, or a physical device and cannot be done from
> this Codespace. Items marked **ME** I can do once the thing above it exists.

**Status 2026-08-18:** the Apple Developer Program and the domain are bought,
and the prices are decided. That clears Phase 0 entirely and unblocks
everything except the two things only a physical iPhone can settle.

## Nothing is blocked on me any more

**Team ID `44R2VVGF8G` — received 2026-08-18 and committed.**
`web/.well-known/apple-app-site-association` now reads
`44R2VVGF8G.app.smooooth.operator`, so universal links will resolve as soon
as the file is actually served (Phase 5). A Team ID is not a secret: this
file publishes it by design, and it appears in every App Store receipt.

Everything remaining in this runbook needs an account, a card, or a physical
iPhone. Work the phases in order — where two are independent, it says so.

**Rough time:** Phase 0b about 25 minutes, Phase 1 about 30, Phase 2 about
40 plus a multi-day wait for the banking agreement, Phase 5 about 30. The
long pole is not effort, it is Apple's review of your tax and banking
details, so start Phase 2 step 10a on day one.

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

## Phase 0b — The Apple Developer portal

All at [developer.apple.com/account](https://developer.apple.com/account),
about 25 minutes. Four things get created here and three of them can only be
downloaded once, so read 3d and 3e before you click.

Your Team ID is **`44R2VVGF8G`** — already in the repo, but you will paste it
into Supabase and GitHub later, so keep it handy.

### 3b. Register the App ID

*Certificates, Identifiers & Profiles* → **Identifiers** → the blue **+**.

1. Select **App IDs** → *Continue*.
2. Select type **App** → *Continue*.
3. **Description:** `Smooooth Operator` (internal only; Apple rejects
   punctuation here, letters and spaces are safe).
4. **Bundle ID:** choose **Explicit**, and type exactly:

   ```
   app.smooooth.operator
   ```

   Four o's in `smooooth`. This must match `App/project.yml` character for
   character — it is compiled into the entitlements, and a mismatch fails at
   signing time with a message that does not mention the bundle ID.
5. Scroll the **Capabilities** list and tick three boxes:

   | Capability | Why |
   |---|---|
   | **Sign in with Apple** | the only sign-in method the app ships |
   | **Associated Domains** | universal links — `/challenge/*` and `/course/*` |
   | **Push Notifications** | see below |

   Push is ticked now even though the app sends none. Adding a capability
   later invalidates the provisioning profile and forces a fresh build and
   upload; ticking an unused one costs nothing. `DriverNotifications` is
   local-only today, so nothing breaks either way.
6. *Continue* → *Register*.

### 3c. Create the Services ID

This is a **separate identifier** from the App ID, and confusing the two is
the single most common Sign-in-with-Apple failure. The App ID identifies the
iOS app; the Services ID identifies the *web* OAuth client, which is what
Supabase acts as.

*Identifiers* → **+** → **Services IDs** → *Continue*.

1. **Description:** `Smooooth Operator Sign In`
2. **Identifier:**

   ```
   app.smooooth.operator.signin
   ```
3. *Continue* → *Register*.
4. Now **click the Services ID you just made** to reopen it, tick **Sign in
   with Apple**, and press **Configure**:
   - **Primary App ID:** `app.smooooth.operator`
   - **Domains and Subdomains:** `smoooothoperator.com`
     (no `https://`, no trailing slash — Apple rejects both)
   - **Return URLs:**

     ```
     https://tsxyxgtjihycaoydyafp.supabase.co/auth/v1/callback
     ```

     This is Supabase's callback, not your domain. Getting it wrong produces
     `invalid_client` at sign-in with no further detail.
5. *Next* → *Done* → *Continue* → **Save**.

> Apple may refuse the domain until it resolves. If it does, come back after
> Phase 5 — this is the one ordering dependency between the two phases.

### 3d. Create the Sign in with Apple key

*Keys* → **+**.

1. **Key Name:** `Smooooth Operator Sign In Key`
2. Tick **Sign in with Apple** → **Configure** → Primary App ID
   `app.smooooth.operator` → *Save*.
3. *Continue* → *Register*.
4. **Download the `.p8` file now.** Apple gives you exactly one chance; there
   is no way to retrieve it afterwards, only to revoke the key and make a new
   one. Put it somewhere you back up.
5. Note the **Key ID** shown on the page — ten characters, and it is *not*
   your Team ID.

You now have, for Phase 1 step 5: Services ID, `.p8` contents, Team ID
`44R2VVGF8G`, Key ID.

### 3e. Create the App Store Connect API key

Different website. [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
→ **Users and Access** → **Integrations** tab → **App Store Connect API** →
**Team Keys** → the **+**.

1. **Name:** `TestFlight CI`
2. **Access:** **App Manager**. *Developer* is not enough — the upload step
   fails with a permissions error at the very end of a 20-minute Mac build.
3. *Generate*.
4. **Download the `.p8`.** Once only, again.
5. Note two values from this page:
   - **KEY ID** — in the key's row
   - **ISSUER ID** — a UUID *above* the table, easy to miss

These three become GitHub secrets in Phase 3.

---

## Phase 1 — Make the backend real

The Supabase project `tsxyxgtjihycaoydyafp` exists but is **empty** —
`public.courses` does not exist there. All 36 migrations are local-only, so
nothing works against production yet. About 30 minutes.

Independent of Phase 2 and Phase 5; do them in any order.

### 4. Push the schema and the catalog

Run from the repo root. `supabase link` asks for the **database password** —
set when the project was created, and resettable under *Project Settings →
Database → Database password* if it is lost (resetting breaks nothing else).

```bash
supabase link --project-ref tsxyxgtjihycaoydyafp
supabase db push          # applies all 36 migrations, in order
```

`db push` prints each migration as it applies and stops on the first error
without leaving a partial state. If it stops, send me the output — a
migration that fails against production but passes locally is usually an
extension the hosted project has not enabled (`postgis`, `pg_cron`).

**`db push` does not load any data.** The seeds are separate files that only
run automatically on a *local* `db reset`, so production needs them applied
by hand — this is the step that is easiest to skip and leaves you with a
working app that has nothing to drive:

```bash
# 1. the active scoring config — WITHOUT THIS, NOTHING CAN BE SCORED
supabase db query --linked -f supabase/seed.sql

# 2. the 803-course catalog (5.4 MB, so psql rather than the API)
psql "<connection string>" -f supabase/seeds/platform_courses.sql
```

The connection string is in the dashboard under *Project Settings → Database
→ Connection string → URI*; use the **session pooler** one and substitute
your password for `[YOUR-PASSWORD]`. The catalog takes a minute or two.

**Verify both, because each fails quietly in its own way:**

```bash
supabase db query --linked "select count(*) from public.courses;"
supabase db query --linked "select version, active from public.scoring_configs;"
```

Expect **803** courses and one row marked `active`. Zero courses gives you an
app with an empty map. No active scoring config is worse: runs upload, the
scorer finds no config, and every drive fails to score with an error the app
reports honestly but which looks like a bug in the engine.
### 5. Turn on Sign in with Apple

Every provider is currently `false`. **Nobody can sign in right now,
including you**, which also means the operator console is unreachable.

Supabase dashboard → *Authentication* → *Sign In / Providers* → **Apple** →
toggle **Enable**, then fill in four fields from Phase 0b:

| Field | Value | Common mistake |
|---|---|---|
| **Client IDs** | `app.smooooth.operator.signin` | pasting the App ID instead of the **Services** ID |
| **Secret Key (for OAuth)** | the entire `.p8` contents from 3d | pasting the filename, or omitting the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| **Team ID** | `44R2VVGF8G` | — |
| **Key ID** | the Key ID from 3d | pasting the Team ID again |

Open the `.p8` in a text editor and copy **everything**, including both
dashed lines and the trailing newline.

Then *Authentication* → **URL Configuration** → **Redirect URLs** → *Add URL*:

```
smooothoperator://auth-callback
```

**Three o's in that scheme.** It is deliberately not the four-o brand name —
it is what `App/project.yml` registers as the URL scheme, and it is the only
way the session gets back into the app. Without this entry sign-in appears to
work and then hangs on a blank Safari sheet.

**Google is optional.** If you want it: Google Cloud console → *APIs &
Services* → *Credentials* → *Create OAuth client ID* → **Web application** →
authorised redirect URI
`https://tsxyxgtjihycaoydyafp.supabase.co/auth/v1/callback`, then paste the
client ID and secret into Supabase's Google provider.

### 6. Deploy the edge functions

```bash
supabase functions deploy score-run today-challenge \
    validate-course resolve-challenge appstore-notifications \
    delete-account purge-telemetry
```

All seven. Each prints a URL when it succeeds.

Then set the two database settings that pg_cron needs. These only exist in
production, which is why they are not in a migration — a migration would bake
the service-role key into version control:

```sql
alter database postgres set app.functions_url =
  'https://tsxyxgtjihycaoydyafp.supabase.co/functions/v1';
alter database postgres set app.service_role_key = '<service role key>';
```

Run them in the dashboard's **SQL Editor**. The service-role key is under
*Project Settings → API → service_role*. **It bypasses every row-level
security policy** — it belongs in this one SQL statement and in
`supabase secrets`, never in a browser, a client, or this repository.

These two settings drive both the retention job and the scoring sweeper.
Without them `purge-telemetry` returns 0 rather than erroring nightly
forever — quiet by design, but it means nothing is ever deleted.

### 7. Set the App Store verification secret

```bash
supabase secrets set APPLE_ROOT_CA_SHA256=<sha256 of Apple's root CA DER>
```

Get it by downloading Apple's root CA and hashing it:

```bash
curl -sO https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
shasum -a 256 AppleRootCA-G3.cer
```

Without this secret the App Store webhook returns **503 on purpose** — it
refuses to process a payload whose signature chain it cannot verify. That is
correct behaviour, and it also means **subscriptions silently never
activate**: a driver pays, Apple notifies, the function refuses, and nothing
in the app changes. Set this before you test a purchase, and before pressing
Apple's *Test* button in Phase 2 step 12.

### 8. Grant yourself operator access

There is deliberately no browser path to this table. Sign in to the app or
the web console once first, so your user row exists, then find your id:

```sql
select id, email from auth.users order by created_at desc limit 5;

insert into public.admins (user_id, note)
values ('<your auth.users id>', 'owner');
```

Verify by loading `/admin.html` on the site — it should show real numbers
rather than refusing. `admin_overview()` throws `42501 not authorised` for
everyone else, including other signed-in users.

### 9. Prices — ✅ already done

Migration `0036` sets $7 / $19 / $99. Nothing to type. If App Store Connect
ends up with different values, tell me and I will correct the migration.

---

## Phase 2 — App Store Connect

[appstoreconnect.apple.com](https://appstoreconnect.apple.com). About 40
minutes of clicking plus a wait measured in days for the agreement.

Independent of Phase 1 and Phase 5, with one exception noted in step 12.

### 10a. Start the Paid Applications agreement — do this first

**Business** → **Agreements** (older accounts: *Agreements, Tax, and
Banking*).

1. Accept the **Paid Applications** agreement.
2. Add a **bank account** — the legal entity's details, matching your tax
   forms exactly.
3. Complete the **tax forms** for your country, plus the US one (W-8BEN or
   W-8BEN-E outside the US, W-9 inside).

This is the slowest item in the entire runbook. Apple reviews it manually,
it can take days, and it sometimes comes back asking for documents. **Until
it shows *Active*, your subscriptions cannot be submitted and nobody can be
charged** — the app would ship with a paywall that cannot complete a
purchase. Start it on day one and let it run while you do everything else.

### 10. Create the app record

**My Apps** → **+** → **New App**.

| Field | Value |
|---|---|
| Platforms | **iOS** |
| Name | your store name — must be globally unique across the App Store |
| Primary language | your choice |
| Bundle ID | **`app.smooooth.operator`** — pick it from the dropdown; it appears because you registered it in 3b |
| SKU | `smooooth-operator` — internal only, never shown |
| User Access | Full Access |

If the bundle ID is missing from the dropdown, the App ID in 3b was not
registered or used a wildcard rather than **Explicit**.

### 11. Create the three subscriptions

**Monetization** → **Subscriptions** → **Create** a subscription group.

- **Reference Name:** `Smooooth Pro` (internal)
- **Localized display name:** what users see at the top of the purchase
  sheet — `Smooooth Pro` is fine.

Then add three subscriptions **inside that one group**. The group matters:
subscriptions in the same group are mutually exclusive and upgrade/downgrade
between each other, which is the behaviour you want. Three separate groups
would let somebody buy weekly *and* yearly simultaneously.

| Reference Name | Product ID | Duration | Price |
|---|---|---|---|
| Pro Weekly | `smooooth.pro.weekly` | 1 Week | **$7** |
| Pro Monthly | `smooooth.pro.monthly` | 1 Month | **$19** |
| Pro Yearly | `smooooth.pro.yearly` | 1 Year | **$99** |

**The Product IDs must be exact.** Both the app and the database match them
by string — `App/Configs/Products.storekit`, the paywall, and the
`product_prices` check constraint all name these three literals. A typo
produces a product that loads in App Store Connect and is invisible to the
app, with no error.

For each subscription you must also fill in, or it cannot be submitted:
- **Subscription Display Name** and **Description** (localized)
- **Availability** — all territories unless you have a reason
- **Price** — see below
- At least one **App Store Promotion** image is *not* required; skip it.

**On the prices.** Apple sells from a fixed list of price points. If $7.00,
$19.00 and $99.00 are not offered in USD, take the nearest — most likely
$6.99, $18.99 and $98.99 — and **tell me the three values you picked**.
Migration `0036` mirrors them for MRR and ARR, and if it disagrees with
reality your revenue reporting is quietly wrong forever with nothing to
signal it. The app itself is unaffected: it shows StoreKit's price.

### 12. Set the App Store Server Notifications URL

**App Information** → scroll to **App Store Server Notifications**.

Set **both** the Production and Sandbox Server URLs to:

```
https://tsxyxgtjihycaoydyafp.supabase.co/functions/v1/appstore-notifications
```

Version: **Version 2**.

Then press **Test**. It should return 200 — the function handles Apple's
`TEST` notification type specifically so this button works.

**Do Phase 1 steps 6 and 7 first.** Without the deployed function the URL
404s, and without `APPLE_ROOT_CA_SHA256` the function returns 503 by design.
Both look like the same failure in Apple's UI.

### 12a. Sign-In Information — leave it unchecked

App Review asks for "a user name and password so we can sign in to your
app." **There is none, and that is the correct answer.** The app offers only
Sign in with Apple and Google; no email/password path exists in the UI, so
credentials would arrive with no field to type them into.

Sign-in is also optional — browsing courses, driving a challenge, being
scored and sharing the card all work with no account. Leave the box
unchecked and paste the notes from `docs/STORE-LISTING.md`, which also cover
what to say if a reviewer asks for credentials anyway.

**What this depends on.** Sign in with Apple must actually work for the
reviewer who tries it: 0b step 3c and Phase 1 step 5 both done, and tested
on a real device before you submit.

**And it expires.** The Apple client secret is a JWT that Apple caps at six
months. `tools/apple-client-secret.mjs` mints it and prints the date. When
it lapses **sign-in breaks for everyone, silently, with no error anywhere** —
put the expiry in a calendar the day you generate it.

### 13. Privacy nutrition labels

**App Privacy** → *Get Started*. Declare exactly three collections:

| Data | Purpose | Linked to identity | Tracking |
|---|---|---|---|
| **Precise Location** | App Functionality | Yes | No |
| **Fitness** (motion) | App Functionality | Yes | No |
| **Purchase History** | App Functionality | Yes | No |

`PrivacyInfo.xcprivacy` already declares the underlying API usage. The
nutrition label is a **separate** form and Apple checks the two agree — a
mismatch is a common rejection. Answer **No** to tracking: the app has no
ad SDK, no attribution, and no third-party analytics.

### 14. Screenshots and copy

Required sizes: **6.9" or 6.7"** (iPhone 16 Pro Max / 15 Pro Max) and
**6.5"**. Apple will scale one set down in some cases, but supply both to be
safe.

The CI demo tour already produces a usable starting set — download the
`screenshots` artifact from the most recent **iOS nightly build** run on
GitHub. Those are simulator captures of the real app.

You also need **Description**, **Keywords**, **Support URL**, **Privacy
Policy URL** and an **App Review** note. All of them are written and
character-counted in **`docs/STORE-LISTING.md`** — copy from there rather
than composing in the form.

**Write the review note carefully.** This app is scored by driving a car,
which a reviewer at a desk cannot do. Tell them so explicitly, and give them
a demo account plus what to expect — a reviewer who cannot make the core
feature work rejects the app. Something like:

> Smooooth Operator scores real driving using GPS and motion sensors, so the
> core loop requires being in a moving vehicle. As a passenger or at a desk,
> the app will show courses and leaderboards but a run cannot be scored — a
> stationary run is correctly reported as ineligible rather than given a
> fabricated score. Demo account: <email> / <password>.

---

## Phase 3 — The build

### 15. Team ID — ✅ done

`44R2VVGF8G`, committed to the AASA file on 2026-08-18. Nothing else in the
repo hard-codes it; the build reads `DEVELOPMENT_TEAM` from a secret.

### 16. Get it onto your iPhone — no Mac required

**You do not need App Store publication to install on a phone**, and it is
not the fastest route either. TestFlight installs a real signed build on a
real device, and for **internal** testers — you, plus up to 99 others on your
App Store Connect team — Apple does not review it first. The build appears
minutes after processing.

Archiving and signing need macOS, which is why this used to imply owning a
Mac. `.github/workflows/testflight.yml` does it on a rented CI Mac instead.

**Add six repository secrets.** GitHub → your repo → *Settings* → *Secrets
and variables* → **Actions** → *New repository secret*, once per row:

| Secret | Value | From |
|---|---|---|
| `APPLE_TEAM_ID` | `44R2VVGF8G` | — |
| `APPSTORE_KEY_ID` | ten characters | Phase 0b step 3e |
| `APPSTORE_ISSUER_ID` | a UUID | Phase 0b step 3e, *above* the key table |
| `APPSTORE_PRIVATE_KEY` | the **entire** `.p8`, `-----BEGIN` and `-----END` lines included | Phase 0b step 3e |
| `SUPABASE_URL` | `https://tsxyxgtjihycaoydyafp.supabase.co` | — |
| `SUPABASE_ANON_KEY` | the publishable key | Supabase → *Settings* → *API* |

The last two are not secrets in the security sense — the anon key ships
inside the binary, and row-level security is what protects data. They are
secrets here because **without them the build produces an app that installs,
launches, and cannot reach the backend at all**: no sign-in, no courses, no
uploads, and nothing on screen to explain why. This was a real gap in the
workflow until 2026-08-18 and would have cost you a build and an afternoon.

The workflow fails immediately, naming any secret that is missing, rather
than letting you discover it forty lines into a signing error.

**Then:** GitHub → *Actions* → **TestFlight** → *Run workflow*. It takes
15–25 minutes. When it finishes, install TestFlight on the iPhone, sign in
with the **same Apple ID** that owns the developer account, and the build
appears under Internal Testing.

**Expect the first run to need a correction.** This workflow has never
executed — it cannot be tested without a paid account, and there is no way to
fake one. The most likely failure is the `method` value in the export
options, which Apple renamed from `app-store` to `app-store-connect` in Xcode
15.3; both are noted in the file. Send me the log and it will be quick.

**Already proven, for free:** the nightly job builds for a real device as
well as the simulator, so the app is known to compile for arm64 against the
device SDK. That was an entire class of failure sitting between here and the
first drive, closed without spending anything.

---

## Phase 4 — The step that actually decides whether this works

### 17. Drive one real course on a real iPhone

**No sensor path in this project has ever seen a real GPS chip.** Every
number, every test, every screenshot in this repository comes from a
simulator feeding synthetic samples through the real pipeline. The engine is
deterministic and heavily tested against those samples — but real GPS drifts,
loses lock under bridges and in tunnels, reports optimistic accuracy figures,
takes tens of seconds to settle after a cold start, and behaves differently
on every handset. The compression work of 2026-08-18 is in the same
position: proven against simulated telemetry, never against a real trace.

**Do this before TestFlight goes wide**, and take a passenger to hold the
phone if you can.

What to watch for, in the order it tends to bite:

1. **Does the run start?** Location permission is requested at first use;
   "Allow Once" is not enough for a background run.
2. **Does it hold lock for the whole course?** The app flags a run with
   insufficient GPS as ineligible rather than scoring it — that is correct
   behaviour, but if it happens on every drive the accuracy thresholds are
   wrong for real hardware.
3. **Is the score plausible?** Not "is it right" — there is no ground truth
   yet — but does a deliberately smooth drive score higher than a
   deliberately jerky one on the same course?
4. **Does the run survive backgrounding?** Lock the phone mid-drive. The
   journal should recover everything.
5. **Does the upload happen, and does the server agree with the phone?** The
   app scores locally and the server rescores authoritatively; a large
   disagreement is the single most valuable bug this drive can surface.

**Then send me the run.** The telemetry is exportable precisely for this —
Profile → export, or pull the raw blob from storage. A single real trace is
worth more than anything else I can build from here, because it is the first
input to this system that I could not have generated.

---

## Phase 5 — The domain and the site (Cloudflare)

**Do this early, not last.** App Store review requires a *reachable* privacy
policy and support URL and Apple checks them during review, so a domain that
resolves the day after you submit is a rejection. Apple may also refuse the
Services ID domain in Phase 0b step 3c until the domain resolves.

Everything here is free beyond the domain you own. About 30 minutes, most of
it waiting for nameservers.

Independent of Phases 1 and 2.

### 18. Put the domain on Cloudflare

**Skip this step if you registered the domain at Cloudflare** — DNS is
already there.

1. [dash.cloudflare.com](https://dash.cloudflare.com) → **Add a site**.
2. Enter `smoooothoperator.com` (apex, no `www`, no `https://`).
3. Choose the **Free** plan.
4. Cloudflare scans existing DNS records and then shows **two nameservers**,
   like `ana.ns.cloudflare.com` and `bob.ns.cloudflare.com`.
5. Go to the registrar you bought the domain from → find **Nameservers** (may
   be called *Custom DNS*) → replace whatever is there with Cloudflare's two
   → save.
6. Wait. Usually minutes, occasionally hours. Cloudflare emails you when the
   site is **Active**. Check with:

   ```bash
   dig +short NS smoooothoperator.com
   ```

### 19. Deploy the site

The site is four static pages plus the AASA file — no build step, nothing to
compile.

```bash
npx wrangler pages deploy web --project-name smoooothoperator
```

Wrangler opens a browser once to authorise, creates the Pages project if it
does not exist, and prints a `*.pages.dev` URL. Open it and confirm the four
pages load: `/`, `/privacy`, `/terms`, `/support`.

If you would rather not use the CLI: Cloudflare dashboard → *Workers & Pages*
→ *Create* → *Pages* → **Upload assets**, name it `smoooothoperator`, and
drag in the contents of the `web/` directory. Do **not** connect the Git
repository — it is private and there is no build to run.

> Tell me and I will run the deploy from here instead; it needs a browser
> once for auth, so you would still have to click through that part.

### 20. Attach the domain

Pages project → **Custom domains** → **Set up a custom domain** → enter
`smoooothoperator.com` → *Activate domain*. Cloudflare creates the DNS record
itself.

**Use the apex, not `www`.** `App/Configs/SmoooothOperator.entitlements`
declares `applinks:smoooothoperator.com` only, and every link the app
generates comes from `Brand.domain`, which is the apex. Adding `www` as a
second custom domain is harmless, but a `www` link will not open the app.

### 21. Verify the AASA file — three silent failures

```bash
curl -sI https://smoooothoperator.com/.well-known/apple-app-site-association
curl -s  https://smoooothoperator.com/.well-known/apple-app-site-association
```

All three of these must hold, and **none of them reports an error anywhere
when it is wrong** — the link simply opens Safari and the feature appears not
to exist:

1. **HTTP 200 with no redirect.** Apple does not follow redirects for this
   file. A `301` from apex to `www`, or from `http` to `https` where the
   redirect lands somewhere unexpected, breaks universal links completely.
   If you see `301` or `308`, fix the Cloudflare redirect rules.
2. **`content-type: application/json`.** Not `text/plain`, not
   `application/octet-stream`. Cloudflare Pages serves the extensionless file
   as JSON already; if you ever move hosts, check this again.
3. **The body contains `44R2VVGF8G.app.smooooth.operator`.** It does in this
   repository as of 2026-08-18 — this check is for after any future edit.

Then test it for real: build to the phone (Phase 3), send yourself a
challenge link, and tap it in Messages. It should open the app, not Safari.
iOS caches this file aggressively — if it opens Safari after a fix,
reinstall the app rather than assuming the file is still wrong.

### 22. Email routing

**Apple rejects apps whose support address bounces**, and they do check.

Cloudflare dashboard → **Email** → **Email Routing** → *Get started*.
Cloudflare adds the MX and TXT records for you.

Create three **custom addresses**, all forwarding to your real inbox:

| Address | Why it exists |
|---|---|
| `support@smoooothoperator.com` | linked from Profile and required by App Review |
| `privacy@smoooothoperator.com` | named in the privacy policy as the data-request address |
| `legal@smoooothoperator.com` | named in the terms |

Cloudflare sends a confirmation email to the destination address. **Click the
link or nothing forwards** — the routes show as created either way.

Verify by sending a message to `support@smoooothoperator.com` from a
different account and watching it arrive. Do not skip this; a route that
silently does not forward looks identical to one that works.

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
