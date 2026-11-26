-- Tahmin Ligi: "Maç Öncesi Bildirimler" (pre-match reminders on players' phones).
-- Paste this whole file into Supabase > SQL Editor and click Run (after schema.sql and live-sync.sql).
-- Safe to run again.
--
-- How it works:
--   * A player turns notifications on in the app; the phone's push address is saved in push_subs
--     (push_subscribe, checked with the player's PIN). Turning them off deletes it (push_unsubscribe).
--   * Supabase Cron runs push_tick() every 5 minutes. When a Süper Lig week or a Champions League
--     day locks within the next 2 hours, and a player with notifications on still has matches in it
--     without a prediction, push_tick() calls the Edge Function "push-reminders", which sends the
--     notification. Each player gets at most one reminder per week / Champions League day.

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.push_subs (
  endpoint    text primary key,                -- the phone's push address (from the browser)
  player_id   text not null references public.players(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.push_sent (
  player_id   text not null references public.players(id) on delete cascade,
  gkey        text not null,                   -- 'tsl:<week>' or 'ucl:<Istanbul date>'
  at          timestamptz not null default now(),
  primary key (player_id, gkey)
);

alter table public.push_subs enable row level security;
alter table public.push_sent enable row level security;
revoke all on public.push_subs, public.push_sent from anon, authenticated;

-- ---------- called by the page ----------
-- Saves this phone's push address for the player (PIN checked). A phone belongs to one player:
-- if another player signs in on it and turns notifications on, the address moves to them.
create or replace function public.push_subscribe(p_player text, p_pin text, p_endpoint text, p_p256dh text, p_auth text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(p_endpoint, '') !~ '^https://\S{10,1000}$'
     or coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_=-]{40,200}$'
     or coalesce(p_auth, '') !~ '^[A-Za-z0-9_=-]{10,100}$' then
    return json_build_object('ok', false, 'error', 'bad_input');
  end if;
  if not _verify_pin(p_player, p_pin) then
    return json_build_object('ok', false, 'error', 'bad_pin');
  end if;
  insert into push_subs (endpoint, player_id, p256dh, auth, created_at)
  values (p_endpoint, p_player, p_p256dh, p_auth, now())
  on conflict (endpoint) do update
    set player_id = excluded.player_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  -- At most 5 phones per player (the newest ones).
  delete from push_subs
   where player_id = p_player
     and endpoint not in (select endpoint from push_subs where player_id = p_player order by created_at desc limit 5);
  return json_build_object('ok', true);
end
$$;

-- Turns notifications off for one phone. The push address is a long random URL that only that
-- phone knows, so no PIN is needed (it also works after a PIN change).
create or replace function public.push_unsubscribe(p_endpoint text)
returns json
language sql
volatile
security definer
set search_path = public
as $$
  with d as (delete from push_subs where endpoint = p_endpoint returning 1)
  select json_build_object('ok', true, 'removed', (select count(*) from d));
$$;

-- ---------- internal ----------
-- Reminders due now: every lock group (Süper Lig week / Champions League Istanbul day) whose first
-- predicted kickoff is within the next 2 hours, for every player with notifications on who has not
-- had this reminder yet, with the number of that group's matches the player has not predicted.
create or replace function public._push_due()
returns table (player_id text, gkey text, comp text, week int, lock_at timestamptz, missing int)
language sql
stable
security definer
set search_path = public
as $$
  with g as (
    select m.id, m.comp, m.week, m.kickoff, m.state,
           case when m.comp = 'ucl' then 'ucl:' || ((m.kickoff at time zone 'Europe/Istanbul')::date)::text
                else 'tsl:' || m.week end as gkey
      from matches m
     where m.predictable and m.comp in ('tsl', 'ucl')
  ), locks as (
    select gkey, min(comp) as comp, min(week) as week, min(kickoff) as lock_at, bool_or(state <> 'pre') as started
      from g group by gkey
  )
  select p.id, l.gkey, l.comp, l.week, l.lock_at,
         (select count(*) from g
           where g.gkey = l.gkey
             and not exists (select 1 from picks k where k.player_id = p.id and k.match_id = g.id))::int
    from locks l
    cross join players p
   where l.lock_at > now() and l.lock_at <= now() + interval '2 hours' and not l.started
     and exists (select 1 from push_subs s where s.player_id = p.id)
     and not exists (select 1 from push_sent x where x.player_id = p.id and x.gkey = l.gkey);
$$;
revoke all on function public._push_due() from public, anon, authenticated;

-- Called by the Edge Function: marks the due reminders as sent and returns one message per phone.
-- Marking first means a reminder is never sent twice, even if two runs overlap.
create or replace function public.push_claim()
returns json
language sql
volatile
security definer
set search_path = public
as $$
  with due as (
    select * from _push_due() where missing > 0
  ), ins as (
    insert into push_sent (player_id, gkey)
    select player_id, gkey from due
    on conflict do nothing
    returning player_id, gkey
  )
  select coalesce(json_agg(json_build_object(
           'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
           'tag', d.gkey,
           'url', case when d.comp = 'ucl' then '#ucl' else '#predict' end,
           'title', case when d.comp = 'ucl' then 'Şampiyonlar Ligi tahminleri'
                         else d.week || '. hafta tahminleri' end,
           'body', d.missing || ' maçı henüz tahmin etmedin. Kilit saati '
                   || to_char(d.lock_at at time zone 'Europe/Istanbul', 'HH24:MI') || ' (ilk maç).')), '[]'::json)
    from due d
    join ins i on i.player_id = d.player_id and i.gkey = d.gkey
    join push_subs s on s.player_id = d.player_id;
$$;

-- Called by the Edge Function: forgets phones whose push address no longer works
-- (the app was removed or notifications were turned off in iPhone Settings).
create or replace function public.push_gone(p_endpoints text[])
returns void
language sql
volatile
security definer
set search_path = public
as $$
  delete from push_subs where endpoint = any (p_endpoints);
$$;

-- Supabase Cron: every 5 minutes. Calls the Edge Function only when a reminder is due.
create or replace function public.push_tick()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  delete from push_sent where at < now() - interval '60 days';
  if exists (select 1 from _push_due() where missing > 0) then
    perform net.http_post(
      url     := 'https://phmvejwbjqhbqzuaomgp.supabase.co/functions/v1/push-reminders',
      body    := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb);
  end if;
end
$$;

revoke all on function public.push_subscribe(text, text, text, text, text) from public;
revoke all on function public.push_unsubscribe(text) from public;
revoke all on function public.push_claim() from public, anon, authenticated;
revoke all on function public.push_gone(text[]) from public, anon, authenticated;
revoke all on function public.push_tick() from public, anon, authenticated;
grant execute on function public.push_subscribe(text, text, text, text, text) to anon, authenticated;
grant execute on function public.push_unsubscribe(text) to anon, authenticated;
grant execute on function public.push_claim() to service_role;
grant execute on function public.push_gone(text[]) to service_role;

-- Run every 5 minutes (re-running this file replaces the job).
select cron.unschedule(jobid) from cron.job where jobname = 'tahmin-push';
select cron.schedule('tahmin-push', '*/5 * * * *', 'select public.push_tick()');

-- Checks (run separately):
--   select player_id, left(endpoint, 40), created_at from push_subs;   -- who has notifications on
--   select * from push_sent order by at desc limit 10;                 -- reminders sent
--   select * from _push_due();                                         -- reminders due right now
