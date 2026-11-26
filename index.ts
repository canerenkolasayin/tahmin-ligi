// Tahmin Ligi: sends the "Maç Öncesi Bildirimler" reminders (Supabase Edge Function "push-reminders").
// Supabase Cron calls it through push_tick() (push.sql) only when a reminder is due. It asks the
// database which reminders to send (push_claim marks them as sent), sends them with Web Push, and
// forgets phones whose push address no longer works. Calling it when nothing is due does nothing.
//
// Needs one secret (Edge Functions > Secrets): VAPID_PRIVATE_KEY.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY = "BHPi08kaKgWymktDdstovFRaq1BXfGfurNC1n7jcE0FzivFn_AP2uB7oYX9sSrd0hb2U1K5JB5pcMv38XP6KKgg";
const SITE = "https://canerenkolasayin.github.io/tahmin-ligi/";

const DB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const DB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function rpc(fn: string, args: Record<string, unknown> = {}) {
  const headers: Record<string, string> = { apikey: DB_KEY, "Content-Type": "application/json" };
  if (DB_KEY.startsWith("eyJ")) headers.Authorization = `Bearer ${DB_KEY}`; // legacy JWT key
  const r = await fetch(`${DB_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${fn}: HTTP ${r.status} ${await r.text()}`);
  const text = await r.text();
  return text ? JSON.parse(text) : null;
}

type Msg = { endpoint: string; p256dh: string; auth: string; title: string; body: string; url: string; tag: string };

Deno.serve(async () => {
  try {
    const priv = Deno.env.get("VAPID_PRIVATE_KEY");
    if (!priv) throw new Error("VAPID_PRIVATE_KEY secret is missing");
    webpush.setVapidDetails(SITE, VAPID_PUBLIC_KEY, priv);

    const msgs: Msg[] = (await rpc("push_claim")) ?? [];
    const gone: string[] = [];
    let sent = 0, failed = 0;
    await Promise.all(msgs.map(async (m) => {
      try {
        await webpush.sendNotification(
          { endpoint: m.endpoint, keys: { p256dh: m.p256dh, auth: m.auth } },
          JSON.stringify({ title: m.title, body: m.body, url: m.url, tag: m.tag }),
          { TTL: 2 * 60 * 60, urgency: "high" },
        );
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) gone.push(m.endpoint);
        else { failed++; console.error("push failed", code, String(e)); }
      }
    }));
    if (gone.length) await rpc("push_gone", { p_endpoints: gone });
    return Response.json({ sent, gone: gone.length, failed });
  } catch (e) {
    console.error(e);
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
