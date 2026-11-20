# Tahmin Ligi

A Süper Lig 2026–27 score-prediction league for four friends.

- **Page:** `index.html`, served by GitHub Pages from the repository root. Players pick their name and enter a 4-digit PIN.
- **Data:** Supabase. `schema.sql` creates the tables and the three functions the page calls
  (`get_state`, `login`, `save_picks`). PINs are checked in the database. A week locks at its first kickoff:
  no prediction for that week can be changed after that, and only then are other players' predictions returned.
- **Scores:** `.github/workflows/sync.yml` runs `sync.mjs` every 10 minutes (09:00–22:59 UTC).
  It reads ESPN's public Süper Lig and Champions League scoreboards (plus the Champions League table)
  and upserts them into Supabase. It needs the repository secret `SUPABASE_SECRET_KEY`.
- **Champions League:** the "Şampiyonlar Ligi" tab shows every match and the league-phase table.
  Every match is predicted; they score like Süper Lig matches and count in the main Puan Tablosu.
  Each day (Istanbul date) locks at that day's first kickoff. Turkish teams' matches are highlighted.

## Scoring

Each match has three pools, split equally between the players who got that category right
(judged from the predicted score): exact score 250, winner (home/away/draw) 200,
both teams to score (yes or no) 150.
