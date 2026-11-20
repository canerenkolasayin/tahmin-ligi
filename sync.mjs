// Tahmin Ligi score sync.
// Fetches the 2026-27 Süper Lig (ESPN league tur.1) and Champions League (uefa.champions)
// fixtures and scores from ESPN's public scoreboard feed, plus the Champions League table,
// and upserts them into Supabase. Runs on GitHub Actions; needs SUPABASE_URL and SUPABASE_SECRET_KEY.

const SUPABASE_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SECRET_KEY;
if (!SUPABASE_URL || !KEY) throw new Error("SUPABASE_URL and SUPABASE_SECRET_KEY must be set");

const ESPN = "https://site.api.espn.com/apis";
const TSL_MONTHS = ["202608", "202609", "202610", "202611", "202612", "202701", "202702", "202703", "202704", "202705"];
const UCL_MONTHS = ["202609", "202610", "202611", "202612", "202701", "202702", "202703", "202704", "202705", "202706"];
const NAMES = {
  "Amed SFK": "Amedspor", "Basaksehir": "Başakşehir", "Istanbul Basaksehir": "Başakşehir",
  "Besiktas": "Beşiktaş", "Caykur Rizespor": "Çaykur Rizespor", "Corum FK": "Çorum FK", "Corum": "Çorum FK",
  "Erzurumspor": "Erzurumspor FK", "Erzurum BB": "Erzurumspor FK", "Eyupspor": "Eyüpspor",
  "Fenerbahce": "Fenerbahçe", "Genclerbirligi": "Gençlerbirliği", "Goztepe": "Göztepe", "Kasimpasa": "Kasımpaşa",
};
const teamName = t => NAMES[t.displayName] || t.displayName;

async function getJson(url) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch(url);
    if (r.ok) return r.json();
    if (attempt === 3) throw new Error(`ESPN ${url}: HTTP ${r.status}`);
    await new Promise(res => setTimeout(res, 2000 * attempt));
  }
}
const fetchEvents = async (league, months) =>
  (await Promise.all(months.map(m => getJson(`${ESPN}/site/v2/sports/soccer/${league}/scoreboard?dates=${m}&limit=300`))))
    .flatMap(j => j.events || []);

function toMatch(e, comp) {
  const c = e.competitions[0];
  const h = c.competitors.find(x => x.homeAway === "home");
  const a = c.competitors.find(x => x.homeAway === "away");
  const st = e.status.type;
  const started = st.state !== "pre";
  return {
    id: String(e.id),
    comp,
    stage: comp === "ucl" ? String((e.season && e.season.slug) || "") : "",
    kickoff: new Date(e.date).toISOString(),
    home: teamName(h.team),
    away: teamName(a.team),
    homeId: String(h.team.id),
    awayId: String(a.team.id),
    hs: started ? Number(h.score) : null,
    as_: started ? Number(a.score) : null,
    state: st.state,
    done: Boolean(st.completed),
    clock: st.state === "in" ? String(e.status.displayClock || "") : "",
    detail: String(st.shortDetail || ""),
  };
}
const dedupe = list => [...new Map(list.map(m => [m.id, m])).values()]
  .sort((x, y) => x.kickoff.localeCompare(y.kickoff) || x.id.localeCompare(y.id));

// Weeks: a 40h+ gap between kickoffs starts a new cluster. With minSize > 1, smaller
// clusters (rescheduled games) join the round before them.
function assignWeeks(all, minSize) {
  let week = 0, prev = null, cluster = [];
  const clusters = [];
  for (const m of all) {
    const t = Date.parse(m.kickoff);
    if (prev === null || t - prev >= 40 * 3600e3) { cluster = []; clusters.push(cluster); }
    cluster.push(m); prev = t;
  }
  for (const g of clusters) {
    if (g.length >= minSize || week === 0) week++;
    for (const m of g) m.week = week;
  }
  return week;
}

const DRY_RUN = process.env.DRY_RUN === "1"; // for local testing: print instead of writing
async function upsert(table, body) {
  if (DRY_RUN) { console.log(`[dry run] ${table}: ${body.length} rows, e.g.`, JSON.stringify(body[0]).slice(0, 300)); return; }
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}?on_conflict=${table === "meta" ? "key" : "id"}`, {
    method: "POST",
    headers: { apikey: KEY, "Content-Type": "application/json", Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`Supabase ${table}: HTTP ${r.status} ${await r.text()}`);
}
const now = new Date().toISOString();
const row = ({ homeId, awayId, ...m }, predictable) => ({ ...m, predictable, updated_at: now });

// ---------- Süper Lig ----------
const tsl = dedupe((await fetchEvents("tur.1", TSL_MONTHS)).map(e => toMatch(e, "tsl")));
if (tsl.length < 100) throw new Error(`Only ${tsl.length} Süper Lig matches returned; refusing to write`);
const tslWeeks = assignWeeks(tsl, 5);
await upsert("matches", tsl.map(m => row(m, true)));
const turkishIds = new Set(tsl.flatMap(m => [m.homeId, m.awayId]));
console.log(`Süper Lig: ${tsl.length} matches in ${tslWeeks} weeks (${tsl.filter(m => m.done).length} finished, ${tsl.filter(m => m.state === "in").length} live).`);

// ---------- Champions League ----------
// A failure here is logged but does not stop the Süper Lig sync.
try {
  // From September only, so summer qualifying rounds are left out.
  const ucl = dedupe((await fetchEvents("uefa.champions", UCL_MONTHS)).map(e => toMatch(e, "ucl")))
    .filter(m => !/qualif/i.test(m.stage));
  if (ucl.length < 100) throw new Error(`only ${ucl.length} matches returned; not writing`);
  const days = assignWeeks(ucl, 1);
  const predicted = ucl.filter(m => turkishIds.has(m.homeId) || turkishIds.has(m.awayId));
  await upsert("matches", ucl.map(m => row(m, turkishIds.has(m.homeId) || turkishIds.has(m.awayId))));

  const st = await getJson(`${ESPN}/v2/sports/soccer/uefa.champions/standings`);
  const entries = ((st.children || [])[0] || {}).standings?.entries || [];
  const stat = (e, n) => Number((e.stats.find(s => s.name === n) || {}).value || 0);
  const table = entries.map(e => ({
    rank: stat(e, "rank"), team: teamName(e.team), tr: turkishIds.has(String(e.team.id)),
    o: stat(e, "gamesPlayed"), g: stat(e, "wins"), b: stat(e, "ties"), m: stat(e, "losses"),
    a: stat(e, "pointsFor"), y: stat(e, "pointsAgainst"), av: stat(e, "pointDifferential"), p: stat(e, "points"),
  })).sort((x, y) => x.rank - y.rank);
  if (table.length) await upsert("meta", [{ key: "ucl_standings", value: JSON.stringify(table) }]);
  console.log(`Champions League: ${ucl.length} matches in ${days} matchdays, ${predicted.length} with Turkish teams; table ${table.length} teams.`);
} catch (err) {
  console.warn(`Champions League sync skipped: ${err.message}`);
}

await upsert("meta", [{ key: "synced_at", value: now }]);
