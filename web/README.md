# smoooothoperator.com

Static site. No build step, no framework, no dependencies — every page is
plain HTML that loads one stylesheet.

| Page | Why it exists |
|---|---|
| `index.html` | Landing page |
| `privacy.html` | **App Store submission blocker.** Apple requires a reachable privacy policy URL. |
| `terms.html` | **Required for auto-renewing subscriptions** (Apple checks for EULA + terms). |
| `support.html` | **App Store submission blocker.** A support URL is mandatory. |
| `admin.html` | Owner-only analytics. `noindex`, and useless without a row in `public.admins`. |
| `.well-known/apple-app-site-association` | Universal links (`/challenge/*`, `/course/*`). Team ID `44R2VVGF8G` is in place. |

## Deploying

Any static host works. Cloudflare Pages is free and fits:

```
npx wrangler pages deploy web --project-name smoooothoperator
```

Netlify, Vercel and GitHub Pages are equally fine — there is nothing to build.

**Two things the host must get right:**

1. `/.well-known/apple-app-site-association` must be served as
   `application/json` **with no extension and no redirect**. Universal links
   silently stop working otherwise, and there is no error to see.
2. HTTPS with no redirect from the apex to `www` (or Apple fetches the AASA
   from the wrong host).

## Before it goes live

- [ ] Put the logo at `web/logo.png` (square, ideally 1024×1024).
- [ ] Fill in `config.js` with the Supabase URL + publishable key.
- [x] ~~Replace `TEAMID` in the AASA file with the real Apple Team ID.~~ Done
      2026-08-18: `44R2VVGF8G`. A Team ID is not a secret — it is served
      publicly in this very file by design, and appears in every receipt.
- [ ] Point `privacy@`, `legal@` and `support@smoooothoperator.com` somewhere a
      person reads. Apple rejects apps whose support address bounces.
- [ ] Grant yourself operator access:
      `insert into public.admins (user_id) values ('<your-auth-uid>');`
- [ ] Enter real prices so MRR stops reading `—`:
      `update public.product_prices set price_minor = 499 where product_id = 'smooooth.pro.monthly';`

## The admin page

Signing in only proves who you are. Whether anything loads is decided by the
database: every `admin_*` function raises `42501` unless `auth.uid()` is in
`public.admins`, and that table has no API grants at all — membership is
granted by direct SQL and cannot be requested from the browser.

If you sign in and see "not an operator account", that is the system working.
