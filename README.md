# Tahmin Ligi

A Süper Lig 2026–27 score-prediction league for four friends.

- **Page:** `index.html`, served by GitHub Pages from the repository root. Players pick their name and enter a 4-digit PIN.
  A signed-in player can choose a new PIN with "PIN'i değiştir" next to their name (current PIN, then the new one
  twice). A forgotten PIN can only be reset in Supabase.
- **Data:** Supabase. `schema.sql` creates the tables and the four functions the page calls
  (`get_state`, `login`, `save_picks`, `change_pin`). PINs are checked in the database. A week locks at its first kickoff:
  no prediction for that week can be changed after that, and only then are other players' predictions returned.
- **Scores:** `.github/workflows/sync.yml` runs `sync.mjs` every 10 minutes (09:00–22:59 UTC).
  It reads ESPN's public Süper Lig and Champions League scoreboards (plus the Champions League table)
  and upserts them into Supabase. It needs the repository secret `SUPABASE_SECRET_KEY`.
- **Live scores:** `live-sync.sql` sets up Supabase Cron to call ESPN every 30 seconds while a match
  is on and update scores in the database. GitHub's schedule is too unreliable for live scores, so the
  GitHub sync is only used for fixtures and week numbers.
- **Champions League:** the "Şampiyonlar Ligi Tahmin" tab shows every match. "Canlı tablo" and
  "Liglerin Puan Tablosu" each have a Süper Lig / Şampiyonlar Ligi toggle: Canlı tablo shows everyone's
  picks and points in the same table for both (a Süper Lig week or a Champions League matchday), and
  Liglerin Puan Tablosu the league tables.
  Every match is predicted; they score like Süper Lig matches and count in the main Puan Tablosu.
  Each day (Istanbul date) locks at that day's first kickoff. Turkish teams' matches are highlighted.

- **Phone app:** the site is a home-screen web app. On an iPhone, open it in Safari, tap Share, then
  "Add to Home Screen" (Turkish: "Ana Ekrana Ekle"). `manifest.webmanifest` and `icons/` give it its name,
  icon and colours; `sw.js` lets it open instantly and offline (the page is always fetched fresh when
  online, Supabase data is never cached). The page also keeps the last loaded data on the phone, so it
  shows the latest known scores straight away. The icon (a football under a floodlight with a cyan "?")
  was drawn as SVG and exported to PNG; to change it, replace the PNGs in `icons/` (180, 192 and 512 px,
  a 512 px maskable version with the artwork at 80% size, and a 32 px favicon).

- **Maç Öncesi Bildirimler:** a signed-in player can turn reminders on or off with the
  "Maç Öncesi Bildirimler" button next to their name (on an iPhone this only works in the home-screen app).
  When a Süper Lig week or a Champions League day locks within 2 hours and the player still has matches
  in it without a prediction, their phone gets one notification. Signing out turns it off on that phone.
  Pieces: `push.sql` (tables, functions and a Supabase Cron job every 5 minutes),
  `supabase/functions/push-reminders/index.ts` (the Edge Function that sends them) and `sw.js`
  (shows the notification). The push key pair (VAPID) is kept outside the repository; the public half
  is in `index.html` and the Edge Function, the private half only in the Edge Function secret
  `VAPID_PRIVATE_KEY`.

  One-time setup in Supabase:
  1. SQL Editor: run `push.sql`.
  2. Edge Functions > Deploy a new function > Via Editor: name it `push-reminders`, paste
     `supabase/functions/push-reminders/index.ts`, deploy. In its settings turn **off** "Verify JWT"
     (Supabase Cron calls it without a login; it only ever sends reminders that are due).
     The dashboard may give it a different web address than its name (here `quick-processor`);
     `push_tick()` in `push.sql` must use the address shown on the function's Overview page.
  3. Edge Functions > Secrets: add `VAPID_PRIVATE_KEY`.

- **Team logos:** `sync.mjs` saves each team's ESPN id (`meta` key `team_ids`, returned by `get_state`).
  The page loads the logo from ESPN's image service at 64 px (white-on-dark version first, then the
  normal one); the browser's own cache keeps them (`sw.js` must not: on iPhone Safari a logo served
  from the service worker cache fails to display). A team without a logo shows its initials. The logo
  files are not stored in this repository (club crests are the clubs' trademarks).

## Scoring

Each match has pools split equally between the players who got that category right
(judged from the predicted score). From Süper Lig week 13 (and Champions League matches played
after week 12): exact score 250, winner (home/away/draw) 200, both teams to score (yes or no) 100,
over/under 2.5 goals 100. Weeks 1–12 used exact 250, winner 200, both teams to score 150.

Puan Tablosu shows the two weeks of the selected week's two-week period (12–13, 14–15, …), ranked by
their sum, plus a table of every period's totals. Champions League matches count in the Süper Lig week
that follows them.
