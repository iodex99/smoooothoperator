# Where the data lives, what you set up, what it costs

> Living document. Answers: is it ready, where does data go, what do you
> need to buy/create, and what do I need from you.

## Short answer on hosting: Supabase. Not AWS.

The whole backend is already written *as* Supabase — Postgres migrations,
row-level security policies, Deno edge functions, Storage buckets. Moving to
AWS would mean rewriting all of it (RDS + Lambda + S3 + Cognito + IAM) for no
benefit at this stage, and you'd lose the thing doing the most work for you:
**row-level security**, where the database itself refuses to hand user A's
data to user B. That's ~1,900 lines of already-tested policy.

Supabase *is* AWS underneath — your Postgres runs on EC2/EBS in the AWS
region you pick. You're buying the managed layer, not a different cloud.

**When you'd revisit:** past roughly 100k monthly actives, or if raw telemetry
storage becomes the dominant cost, the natural move is to keep Supabase for
Postgres/auth and move telemetry blobs to Cloudflare R2 (no egress fees).
That's a one-file change — telemetry access is already behind a single
storage path in the uploader and the scorer. Don't do it now.

---

## Every piece of data, and where it sits

| What | Where | Size | Sensitivity |
|---|---|---|---|
| **Account** — Apple user id, username, display name, country/region/city (self-declared) | Postgres `profiles` | ~200 bytes/user | Low. No email or real name required, no password ever. |
| **Runs** — score, sub-scores, duration, distance, verdict, integrity flags, ~1 Hz preview polyline | Postgres `runs` | ~5 KB/run | Medium. This is the competitive record. |
| **Raw telemetry** — every GPS fix (10 Hz) and IMU sample (50 Hz) for the drive | Supabase **Storage** (private bucket), pointer row in `telemetry` | **~20 MB/run uncompressed today**; ~2–3 MB gzipped | **Highest.** This is a precise trace of where a person drove and how. |
| **Ghosts** — normalized pace along the course | Postgres `ghosts` | ~10 KB/run | Low by design: progress + elapsed time only, never raw coordinates. |
| **Leaderboards** — best verified run per user per course | Postgres `leaderboard_entries` | ~100 bytes/entry | Public by design. |
| **Courses** — the 397-course catalog + user-created courses | Postgres `courses` + `course_checkpoints` (PostGIS) | ~2.5 MB total today | Public. Derived from OpenStreetMap (ODbL — the About screen must credit OSM). |
| **Friendships, challenges, assignments, achievements** | Postgres | tiny | Medium. |
| **Subscriptions** — Apple's original transaction id, status, expiry | Postgres `subscriptions` | tiny | Medium. No card data ever touches us — Apple handles payment entirely. |
| **Pending runs (device only)** | iPhone, Application Support | ~20 MB/queued run | Never leaves the phone until upload. |
| **Session tokens (device only)** | iPhone Keychain, `ThisDeviceOnly` | bytes | Excluded from iCloud and backups. |

**The one number that matters:** raw telemetry dominates everything else by
about 4,000×. At 10,000 active drivers doing 4 runs a month, that's roughly
**120 GB/month of new blobs uncompressed**, or ~15 GB/month gzipped.

Two things to do before that becomes a bill:
1. **Compress before upload** (gzip the NDJSON) — ~8× reduction, one change in the uploader.
2. **Set a retention policy.** Raw telemetry is only needed to re-score a run or investigate a cheat report. Keeping it 90 days and then deleting is defensible, cheap, and better privacy. *(Not yet implemented — currently blobs are kept forever.)*

---

## What you need to set up

### 1. Apple Developer Program — **$99/year, required, blocks everything**
Sign in with Apple, TestFlight and the App Store all require it. Nothing
ships without this. Enrol at developer.apple.com. Individual is fine to
start; an LLC/company enrolment lets the app be published under a company
name instead of your personal one.

Once enrolled, in the Apple Developer portal:
- Register the App ID `app.smooooth.operator` with **Sign in with Apple** and **Associated Domains** capabilities.
- Note your **Team ID** — I need it (see below).

### 2. Supabase project — **free to start, $25/month at scale**
1. Create a project at supabase.com. **Pick the region closest to your first users** — this is the single decision you can't easily change later.
2. Settings → API gives you two values: the **Project URL** and the **anon key**. Both are public and safe in the app binary; row-level security is what protects data.
3. There is also a **service role key**. It bypasses every security policy. It goes in Supabase's own edge-function secrets and *nowhere else* — never in the app, never in git, never in a message to me.
4. Deploy what's already written: `supabase link --project-ref <ref>` then `supabase db push` (14 migrations) and `supabase functions deploy` (4 functions), then load the 397-course seed.

**Free tier limits:** 500 MB database, 1 GB storage, 50k monthly actives — genuinely enough for launch and early beta. Pro ($25/mo) raises that to 8 GB database and 100 GB storage.

### 3. A domain — **~$15/year**
`smooooth.app` (or whatever you choose) needs to serve four things, all of
which are App Store requirements or already referenced by the app:
- `/.well-known/apple-app-site-association` — makes shared challenge links open the app *(the file exists in the repo; it needs your Team ID substituted)*
- `/privacy` — **required** for App Store review
- `/terms` — **required** for auto-renewable subscriptions
- `/support` — required, and already linked from Profile

A static host (Cloudflare Pages, Netlify, GitHub Pages) is free and enough.

### 4. App Store Connect — free, but time-gated
Create the app record, then the three subscription products
(`smooooth.pro.weekly` / `.monthly` / `.yearly` — ids already match the code).
To take money you must also complete the **Paid Applications agreement** with
banking and tax details, which can take days. Start it early.

---

## What I need from you

Only three things, none of them secret:

1. **Your Supabase Project URL and anon key** — I put them in a gitignored config file and the app starts talking to your server. (Not the service role key.)
2. **Your Apple Team ID** — a 10-character string, to finish the universal-links file.
3. **Your chosen domain**, if it isn't `smooooth.app`.

I can do everything else from here: deploy the migrations and functions,
seed the catalog, wire the webhook, write the privacy and terms pages, and
keep driving the CI Mac for builds.

**What I cannot do:** anything requiring your Apple account credentials —
enrolment, agreements, App Store submission, and the physical-device test
drive. Those are yours.

---

## Rough cost at three scales

Estimates, not quotes — verify current pricing before committing.

| | 1,000 users | 10,000 users | 100,000 users |
|---|---|---|---|
| Apple Developer | $8/mo | $8/mo | $8/mo |
| Supabase | $0 (free tier) | $25/mo | $25 + usage, ~$150–400/mo |
| Telemetry storage *(compressed + 90-day retention)* | negligible | ~$1/mo | ~$25/mo |
| Telemetry storage *(as built today — uncompressed, kept forever)* | ~$3/mo | ~$60/mo by year end | **~$800/mo by year end** |
| Domain | $1/mo | $1/mo | $1/mo |
| **Total** | **~$10/mo** | **~$35/mo** | **~$200–450/mo** |

That last row is why compression and retention are on the pre-launch list
rather than the someday list.

Revenue for comparison: at 10,000 users and a 3% conversion to $5/month,
that's ~$1,500/month gross, ~$1,275 after Apple's 15% small-business rate.

---

## Is it ready?

**No — and here is exactly what stands between here and the App Store.**

**Blocking (must happen, in order):**
1. Apple Developer Program enrolment — gates everything below.
2. Supabase project created and the backend deployed to it.
3. **One real drive on a real iPhone.** Every sensor path is tested against a simulator; none has ever seen a real GPS chip on a real road. This is the single highest-risk unknown in the project.
4. Privacy policy, terms, and support pages live on your domain.
5. StoreKit sandbox purchase tested end to end.
6. App Store Server Notifications endpoint — without it the server never learns about subscriptions, and the one Pro-gated feature currently refuses *paying* users.

**Should happen before launch:**
7. Telemetry compression and a retention policy (see the cost table).
8. Run history and real profile records — the app records runs and never shows you them.
9. Friends actually wired (the screen exists, the buttons do nothing).
10. Accessibility pass — there are currently no VoiceOver labels anywhere.

**Honest read:** the engine, the database, the security model and the course
catalog are in good shape and well tested. What's missing is the last mile of
*productization* — and the one genuinely unknown risk is how the telemetry
engine behaves on a real road, which no amount of simulation will settle.
