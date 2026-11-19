# Tahmin Ligi

A Süper Lig 2026–27 score-prediction league for four friends.

- **Page:** `docs/index.html`, served by GitHub Pages. Players pick their name and enter a 4-digit PIN.
- **Data:** Supabase. `supabase/schema.sql` creates the tables and the three functions the page calls
  (`get_state`, `login`, `save_picks`). PINs are checked in the database, predictions lock at kickoff,
  and other players' predictions are only returned after kickoff.
- **Scores:** `.github/workflows/sync.yml` runs `sync/sync.mjs` every 10 minutes (09:00–22:59 UTC).
  It reads ESPN's public Süper Lig scoreboard and upserts the matches into Supabase.
  It needs the repository secret `SUPABASE_SECRET_KEY`.

## Scoring

Each match has three pools, split equally between the players who got that category right
(judged from the predicted score): exact score 250, winner (home/away/draw) 200,
both teams to score (yes or no) 150.
