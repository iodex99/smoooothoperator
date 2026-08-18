-- 0036: the real Pro prices, as decided by the owner on 2026-08-18.
--
--   weekly   $7
--   monthly  $19
--   yearly   $99
--
-- WHAT THIS TABLE IS AND IS NOT. It is a MIRROR, used for one thing: the
-- operator console's MRR and ARR. The app never reads it — the paywall shows
-- `product.displayPrice` straight from StoreKit, so what a driver is charged
-- is whatever App Store Connect says, in their own currency, and no number
-- in this repository can contradict it.
--
-- The consequence is that this table can be WRONG without anything breaking
-- loudly: if App Store Connect ends up with $6.99 because the exact round
-- price point was not offered, revenue reporting is quietly off by 0.14%
-- forever. So it is set here, in version control, rather than typed into a
-- SQL console once and forgotten — and if the App Store price differs, this
-- is the file to change.
--
-- Minor units, because money in a float is a bug waiting for a rounding.

insert into public.product_prices (product_id, price_minor, currency, period_days)
values
    ('smooooth.pro.weekly',   700, 'USD',   7),
    ('smooooth.pro.monthly', 1900, 'USD',  30),
    ('smooooth.pro.yearly',  9900, 'USD', 365)
on conflict (product_id) do update
    set price_minor = excluded.price_minor,
        currency    = excluded.currency,
        updated_at  = now();
