# Tahmin Ligi

A Süper Lig 2026–27 score-prediction league for four friends.

- **Page:** `index.html`, served by GitHub Pages from the repository root. Players pick their name and enter a 4-digit PIN.
- **Data:** Supabase. `schema.sql` creates the tables and the three functions the page calls
  (`get_state`, `login`, `save_picks`). PINs are checked in the database. A week locks at its first kickoff:
  no prediction for that week can be changed after that, and only then are other players' predictions returned.
- **Scores:** `.github/workflows/sync.yml` runs `sync.mjs` every 10 minutes (09:00–22:59 UTC).
  It reads ESPN's public Süper Lig and Champions League scoreboards (plus the Champions League table)
  and upserts them into Supabase. It needs the repository secret `SUPABASE_SECRET_KEY`.
- **Live scores:** `live-sync.sql` sets up Supabase Cron to call ESPN every 30 seconds while a match
  is on and update scores in the database. GitHub's schedule is too unreliable for live scores, so the
  GitHub sync is only used for fixtures and week numbers.
- **Champions League:** the "Şampiyonlar Ligi" tab shows every match and the league-phase table.
  Every match is predicted; they score like Süper Lig matches and count in the main Puan Tablosu.
  Each day (Istanbul date) locks at that day's first kickoff. Turkish teams' matches are highlighted.

## Scoring

Each match has pools split equally between the players who got that category right
(judged from the predicted score). From Süper Lig week 13 (and Champions League matches played
after week 12): exact score 250, winner (home/away/draw) 200, both teams to score (yes or no) 100,
over/under 2.5 goals 150. Weeks 1–12 used exact 250, winner 200, both teams to score 150.

Puan Tablosu shows the season total, the selected week and its two-week period (12–13, 14–15, …),
plus a table of all periods. Champions League matches count in the Süper Lig week that follows them.
