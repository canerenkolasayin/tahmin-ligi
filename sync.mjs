// Tahmin Ligi score sync.
// Fetches the 2026-27 Süper Lig fixtures and scores from ESPN's public scoreboard
// feed (league tur.1) and upserts them into the Supabase "matches" table.
// Runs on GitHub Actions; needs SUPABASE_URL and SUPABASE_SECRET_KEY.

const SUPABASE_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SECRET_KEY;
if (!SUPABASE_URL || !KEY) throw new Error("SUPABASE_URL and SUPABASE_SECRET_KEY must be set");

const MONTHS = ["202608", "202609", "202610", "202611", "202612", "202701", "202702", "202703", "202704", "202705"];
const NAMES = {
  "Amed SFK": "Amedspor", "Basaksehir": "Başakşehir", "Istanbul Basaksehir": "Başakşehir",
  "Besiktas": "Beşiktaş", "Caykur Rizespor": "Çaykur Rizespor", "Corum FK": "Çorum FK", "Corum": "Çorum FK",
  "Erzurumspor": "Erzurumspor FK", "Erzurum BB": "Erzurumspor FK", "Eyupspor": "Eyüpspor",
  "Fenerbahce": "Fenerbahçe", "Genclerbirligi": "Gençlerbirliği", "Goztepe": "Göztepe", "Kasimpasa": "Kasımpaşa",
};
const teamName = t => NAMES[t.displayName] || t.displayName;

async function fetchMonth(m) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch(`https://site.api.espn.com/apis/site/v2/sports/soccer/tur.1/scoreboard?dates=${m}&limit=300`);
    if (r.ok) return (await r.json()).events || [];
    if (attempt === 3) throw new Error(`ESPN ${m}: HTTP ${r.status}`);
    await new Promise(res => setTimeout(res, 2000 * attempt));
  }
}

const events = (await Promise.all(MONTHS.map(fetchMonth))).flat();
const byId = new Map();
for (const e of events) {
  const c = e.competitions[0];
  const h = c.competitors.find(x => x.homeAway === "home");
  const a = c.competitors.find(x => x.homeAway === "away");
  const st = e.status.type;
  const started = st.state !== "pre";
  byId.set(String(e.id), {
    id: String(e.id),
    kickoff: new Date(e.date).toISOString(),
    home: teamName(h.team),
    away: teamName(a.team),
    hs: started ? Number(h.score) : null,
    as_: started ? Number(a.score) : null,
    state: st.state,
    done: Boolean(st.completed),
    clock: st.state === "in" ? String(e.status.displayClock || "") : "",
    detail: String(st.shortDetail || ""),
  });
}
const all = [...byId.values()].sort((x, y) => x.kickoff.localeCompare(y.kickoff) || x.id.localeCompare(y.id));
if (all.length < 100) throw new Error(`Only ${all.length} matches returned; refusing to write`);

// Weeks: a 40h+ gap between kickoffs starts a new cluster. Clusters of 5+ matches are
// rounds; smaller ones (rescheduled games) join the round before them.
let week = 0, prev = null, cluster = [];
const clusters = [];
for (const m of all) {
  const t = Date.parse(m.kickoff);
  if (prev === null || t - prev >= 40 * 3600e3) { cluster = []; clusters.push(cluster); }
  cluster.push(m); prev = t;
}
for (const g of clusters) {
  if (g.length >= 5 || week === 0) week++;
  for (const m of g) m.week = week;
}

const now = new Date().toISOString();
const rows = all.map(m => ({ ...m, updated_at: now }));

async function upsert(table, body) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}?on_conflict=${table === "meta" ? "key" : "id"}`, {
    method: "POST",
    headers: { apikey: KEY, "Content-Type": "application/json", Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`Supabase ${table}: HTTP ${r.status} ${await r.text()}`);
}
await upsert("matches", rows);
await upsert("meta", [{ key: "synced_at", value: now }]);

const live = all.filter(m => m.state === "in").length;
const done = all.filter(m => m.done).length;
console.log(`Synced ${all.length} matches in ${week} weeks (${done} finished, ${live} live).`);
