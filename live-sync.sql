-- Tahmin Ligi: live score updates from inside Supabase.
-- Paste this whole file into Supabase > SQL Editor and click Run (after schema.sql). Safe to run again.
--
-- Why: GitHub's scheduled workflows are "best effort" and in practice ran only a couple of times
-- a day, so live scores lagged by hours. Supabase Cron (pg_cron) runs live_tick() every 30 seconds.
-- live_tick() only calls ESPN while a match is on (10 minutes before kickoff until it finishes,
-- at most 4 hours), so it is idle most of the time.
--
-- Each tick:
--   1. applies ESPN responses requested on the previous tick (pg_net requests are asynchronous):
--      scores, state, clock and kickoff of existing matches, and the Champions League table;
--   2. requests today's ESPN scoreboard for every competition with a match on.
-- Fixtures (new or moved matches, week numbers) still come from the GitHub sync (sync.mjs).

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.live_requests (
  id          bigint primary key,           -- pg_net request id
  kind        text not null,                -- 'tsl' | 'ucl' | 'ucl_table'
  created_at  timestamptz not null default now()
);
alter table public.live_requests enable row level security;
revoke all on public.live_requests from anon, authenticated;

-- ESPN team names -> the names the app uses (same list as sync.mjs).
create or replace function public._espn_name(n text)
returns text
language sql
immutable
as $$
  select coalesce(('{"Amed SFK":"Amedspor","Basaksehir":"Başakşehir","Istanbul Basaksehir":"Başakşehir",
    "Besiktas":"Beşiktaş","Caykur Rizespor":"Çaykur Rizespor","Corum FK":"Çorum FK","Corum":"Çorum FK",
    "Erzurumspor":"Erzurumspor FK","Erzurum BB":"Erzurumspor FK","Eyupspor":"Eyüpspor",
    "Fenerbahce":"Fenerbahçe","Genclerbirligi":"Gençlerbirliği","Goztepe":"Göztepe","Kasimpasa":"Kasımpaşa"}'::jsonb) ->> n, n);
$$;

-- One value from an ESPN standings entry's stats list.
create or replace function public._espn_stat(en jsonb, n text)
returns numeric
language sql
immutable
as $$
  select coalesce((select (s->>'value')::numeric from jsonb_array_elements(en->'stats') s where s->>'name' = n limit 1), 0);
$$;

create or replace function public.live_tick()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  q        record;
  body     jsonb;
  e        jsonb;
  hm       jsonb;
  aw       jsonb;
  st       text;
  v_table  jsonb;
  applied  int := 0;
begin
  -- 1) Apply responses that have arrived.
  for q in
    select lr.id, lr.kind, r.status_code, r.content
      from live_requests lr
      join net._http_response r on r.id = lr.id
  loop
    begin
      if q.status_code = 200 and q.content is not null then
        body := q.content::jsonb;
        if q.kind in ('tsl', 'ucl') then
          for e in select * from jsonb_array_elements(coalesce(body->'events', '[]'::jsonb)) loop
            select c into hm from jsonb_array_elements(e->'competitions'->0->'competitors') c where c->>'homeAway' = 'home';
            select c into aw from jsonb_array_elements(e->'competitions'->0->'competitors') c where c->>'homeAway' = 'away';
            st := e->'status'->'type'->>'state';
            update matches set
              kickoff    = (e->>'date')::timestamptz,
              hs         = case when st <> 'pre' then (hm->>'score')::int end,
              as_        = case when st <> 'pre' then (aw->>'score')::int end,
              state      = st,
              done       = coalesce((e->'status'->'type'->>'completed')::boolean, false),
              clock      = case when st = 'in' then coalesce(e->'status'->>'displayClock', '') else '' end,
              detail     = coalesce(e->'status'->'type'->>'shortDetail', ''),
              updated_at = now()
            where id = e->>'id' and comp = q.kind;
            applied := applied + 1;
          end loop;
        elsif q.kind = 'ucl_table' then
          select jsonb_agg(jsonb_build_object(
                   'rank', _espn_stat(en, 'rank')::int,
                   'team', _espn_name(en->'team'->>'displayName'),
                   'tr',   exists (select 1 from matches m
                                    where m.comp = 'tsl'
                                      and _espn_name(en->'team'->>'displayName') in (m.home, m.away)),
                   'o',  _espn_stat(en, 'gamesPlayed')::int,   'g', _espn_stat(en, 'wins')::int,
                   'b',  _espn_stat(en, 'ties')::int,          'm', _espn_stat(en, 'losses')::int,
                   'a',  _espn_stat(en, 'pointsFor')::int,     'y', _espn_stat(en, 'pointsAgainst')::int,
                   'av', _espn_stat(en, 'pointDifferential')::int, 'p', _espn_stat(en, 'points')::int)
                 order by _espn_stat(en, 'rank'))
            into v_table
            from jsonb_array_elements(coalesce(body->'children'->0->'standings'->'entries', '[]'::jsonb)) en;
          if coalesce(jsonb_array_length(v_table), 0) > 0 then
            insert into meta (key, value) values ('ucl_standings', v_table::text)
            on conflict (key) do update set value = excluded.value;
          end if;
        end if;
      end if;
    exception when others then
      raise warning 'live_tick: could not apply ESPN response % (%): %', q.id, q.kind, sqlerrm;
    end;
    delete from live_requests where id = q.id;
  end loop;
  delete from live_requests where created_at < now() - interval '5 minutes';  -- never answered

  if applied > 0 then
    insert into meta (key, value)
    values ('synced_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
    on conflict (key) do update set value = excluded.value;
  end if;

  -- 2) Ask ESPN again for every competition and day with a match on.
  for q in
    select distinct comp, to_char(kickoff at time zone 'utc', 'YYYYMMDD') as day
      from matches
     where not done
       and kickoff between now() - interval '4 hours' and now() + interval '10 minutes'
  loop
    insert into live_requests (id, kind)
    values (net.http_get(
              url := format('https://site.api.espn.com/apis/site/v2/sports/soccer/%s/scoreboard?dates=%s&limit=100',
                            case q.comp when 'ucl' then 'uefa.champions' else 'tur.1' end, q.day),
              headers := '{"User-Agent": "tahmin-ligi/1.0"}'::jsonb),
            q.comp);
  end loop;

  -- The Champions League table, while its matches are on or just finished.
  if exists (select 1 from matches where comp = 'ucl' and kickoff between now() - interval '5 hours' and now()) then
    insert into live_requests (id, kind)
    values (net.http_get(
              url := 'https://site.api.espn.com/apis/v2/sports/soccer/uefa.champions/standings',
              headers := '{"User-Agent": "tahmin-ligi/1.0"}'::jsonb),
            'ucl_table');
  end if;
end
$$;
revoke all on function public.live_tick() from public, anon, authenticated;

-- Run every 30 seconds (re-running this file replaces the job).
select cron.unschedule(jobid) from cron.job where jobname = 'tahmin-live';
select cron.schedule('tahmin-live', '30 seconds', 'select public.live_tick()');

-- Check that it works (run these separately, a minute after a match has started):
--   select status_code, left(content, 80), created from net._http_response order by created desc limit 5;
--   select value from meta where key = 'synced_at';
