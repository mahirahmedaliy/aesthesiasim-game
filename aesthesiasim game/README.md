# AesthesiaSim

An anaesthesia simulator game and cardiovascular clinical-exam trainer that runs in the browser.

- **Simulator:** 11 patient cases from pre-op to PACU, with a live monitor, ventilator, drugs, an infusion rack and critical events.
- **Clinical exam (CVS):** inspect, palpate and auscultate with synthesised heart sounds, order tests, then submit your findings for marking.
- **Accounts:** Supabase handles login, cloud saves, the leaderboard and the admin dashboard.

## Run locally
Open `index.html` in a browser. Everything is in one file. Logins only work when the page is served from a real web address.

## Deploy
The repo is a static site with no build step. On Vercel: **Add New → Project → Import this repo → Framework: Other → Deploy**.

## Supabase
1. In the SQL Editor, run `supabase/setup.sql` (tables, security and functions).
2. Authentication → URL Configuration: set the Site URL to your domain and add `https://YOUR-DOMAIN/**` to Redirect URLs.
3. Sign up in the game, then make yourself admin:
   `update public.profiles set is_admin = true where email = 'you@example.com';`

The Supabase URL and publishable key in `index.html` are safe to be public, because row-level security protects the data. Never commit the `service_role` key.
