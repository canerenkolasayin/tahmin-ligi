-- Tahmin Ligi database setup.
-- Paste this whole file into Supabase > SQL Editor and click Run. Safe to run again.
--
-- Security model:
--   * Every table has row-level security on and no grants to the public (anon) role,
--     so the web page cannot read or write any table directly.
--   * The page only calls four functions: get_state, login, save_picks and change_pin.
--   * PINs are stored as bcrypt hashes and checked inside the database.
--   * A week locks when its first match kicks off: from then on no prediction for any
--     match of that week can be saved, and everyone's predictions for it are returned.
--   * The score sync (GitHub Actions) uses the secret key, which can write matches and meta.

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists public.players (
  id        text primary key,
  name      text not null,
  short     text not null,
  ord       int  not null default 0,
  pin_hash  text not null
);

create table if not exists public.matches (
  id          text primary key,           -- ESPN event id
  week        int  not null,
  kickoff     timestamptz not null,
  home        text not null,
  away        text not null,
  hs          int,
  as_         int,
  state       text not null default 'pre', -- pre | in | post
  done        boolean not null default false,
  clock       text not null default '',
  detail      text not null default '',
  updated_at  timestamptz not null default now()
);

-- Champions League support (added later; safe to run on an existing database).
--   comp:        'tsl' = Süper Lig, 'ucl' = Champions League
--   predictable: whether players predict this match (all Süper Lig matches; only
--                Turkish teams' Champions League matches)
--   stage:       ESPN round slug for Champions League matches (league-phase, round-of-16, ...)
alter table public.matches add column if not exists comp        text    not null default 'tsl';
alter table public.matches add column if not exists predictable boolean not null default true;
alter table public.matches add column if not exists stage       text    not null default '';

create table if not exists public.picks (
  player_id   text not null references public.players(id) on delete cascade,
  match_id    text not null references public.matches(id) on delete cascade,
  h           int  not null check (h between 0 and 20),
  a           int  not null check (a between 0 and 20),
  updated_at  timestamptz not null default now(),
  primary key (player_id, match_id)
);

create table if not exists public.pin_attempts (
  id         bigserial primary key,
  player_id  text not null,
  at         timestamptz not null default now(),
  ok         boolean not null
);

create table if not exists public.meta (
  key    text primary key,
  value  text not null
);

alter table public.players      enable row level security;
alter table public.matches      enable row level security;
alter table public.picks        enable row level security;
alter table public.pin_attempts enable row level security;
alter table public.meta         enable row level security;

revoke all on public.players, public.matches, public.picks, public.pin_attempts, public.meta from anon, authenticated;
grant select, insert, update, delete on public.matches, public.meta to service_role;

-- ---------- PIN check (internal, not callable from the page) ----------
create or replace function public._verify_pin(p_player text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_fails int;
begin
  delete from pin_attempts where at < now() - interval '1 day';
  select count(*) into v_fails
    from pin_attempts
   where player_id = p_player and not ok and at > now() - interval '15 minutes';
  if v_fails >= 8 then
    raise exception 'locked';
  end if;
  select pin_hash into v_hash from players where id = p_player;
  if v_hash is null then
    return false;
  end if;
  if crypt(coalesce(p_pin, ''), v_hash) = v_hash then
    insert into pin_attempts (player_id, ok) values (p_player, true);
    return true;
  end if;
  insert into pin_attempts (player_id, ok) values (p_player, false);
  return false;
end
$$;
revoke all on function public._verify_pin(text, text) from public, anon, authenticated;

-- ---------- week lock (internal) ----------
-- A week (Süper Lig) or matchday (Champions League) is locked once any of its predicted
-- matches has kicked off or is live, i.e. from its first predicted kickoff.
create or replace function public._week_locked(p_comp text, p_week int)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from matches
                  where comp = p_comp and week = p_week and predictable
                    and (kickoff <= now() or state = 'in'));
$$;
revoke all on function public._week_locked(text, int) from public, anon, authenticated;

-- Is this match's lock group locked? Süper Lig: the whole week, from its first kickoff.
-- Champions League: each day (Istanbul date) separately, from that day's first kickoff.
create or replace function public._match_locked(p_comp text, p_week int, p_kickoff timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case when p_comp = 'ucl' then
    exists (select 1 from matches
             where comp = 'ucl' and predictable
               and (kickoff at time zone 'Europe/Istanbul')::date = (p_kickoff at time zone 'Europe/Istanbul')::date
               and (kickoff <= now() or state = 'in'))
  else _week_locked(p_comp, p_week) end;
$$;
revoke all on function public._match_locked(text, int, timestamptz) from public, anon, authenticated;

-- ---------- public functions ----------
-- Everything the page shows. Other players' scores are only included once the week
-- is locked; before that the page only learns that a prediction exists.
create or replace function public.get_state()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'players', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'short', short, 'ord', ord) order by ord), '[]'::json) from players),
    'matches', (select coalesce(json_agg(json_build_object(
                  'id', id, 'week', week, 'kickoff', kickoff, 'home', home, 'away', away,
                  'hs', hs, 'as', as_, 'state', state, 'done', done, 'clock', clock, 'detail', detail,
                  'comp', comp, 'predictable', predictable, 'stage', stage)
                  order by kickoff, id), '[]'::json) from matches),
    'picks',   (select coalesce(json_agg(json_build_object('p', p.player_id, 'm', p.match_id, 'h', p.h, 'a', p.a)), '[]'::json)
                  from picks p join matches m on m.id = p.match_id
                 where _match_locked(m.comp, m.week, m.kickoff)),
    'submitted', (select coalesce(json_agg(json_build_object('p', p.player_id, 'm', p.match_id)), '[]'::json)
                  from picks p join matches m on m.id = p.match_id
                 where not _match_locked(m.comp, m.week, m.kickoff)),
    'ucl_table', (select value::json from meta where key = 'ucl_standings'),
    'synced_at', (select value from meta where key = 'synced_at'),
    'now', now()
  );
$$;

-- Checks a PIN and returns that player's own predictions (including future ones).
create or replace function public.login(p_player text, p_pin text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if not _verify_pin(p_player, p_pin) then
    return json_build_object('ok', false);
  end if;
  return json_build_object(
    'ok', true,
    'picks', (select coalesce(json_agg(json_build_object('m', match_id, 'h', h, 'a', a)), '[]'::json)
                from picks where player_id = p_player)
  );
end
$$;

-- Saves up to 50 predictions: [{"m": "<match id>", "h": 2, "a": 1}, ...]
-- Matches in a locked week (its first match has kicked off), or scores outside 0-20, are skipped.
create or replace function public.save_picks(p_player text, p_pin text, p_picks jsonb)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  r        jsonb;
  v_m      matches%rowtype;
  v_saved  int := 0;
  v_skip   int := 0;
begin
  if not _verify_pin(p_player, p_pin) then
    return json_build_object('ok', false, 'error', 'bad_pin');
  end if;
  if p_picks is null or jsonb_typeof(p_picks) <> 'array' or jsonb_array_length(p_picks) > 50 then
    return json_build_object('ok', false, 'error', 'bad_input');
  end if;
  for r in select * from jsonb_array_elements(p_picks) loop
    select * into v_m from matches where id = r->>'m';
    if not found
       or not v_m.predictable
       or v_m.kickoff <= now() or v_m.state <> 'pre' or _match_locked(v_m.comp, v_m.week, v_m.kickoff)
       or coalesce(r->>'h', '') !~ '^[0-9]{1,2}$' or coalesce(r->>'a', '') !~ '^[0-9]{1,2}$'
       or (r->>'h')::int > 20 or (r->>'a')::int > 20 then
      v_skip := v_skip + 1;
      continue;
    end if;
    insert into picks (player_id, match_id, h, a, updated_at)
    values (p_player, v_m.id, (r->>'h')::int, (r->>'a')::int, now())
    on conflict (player_id, match_id) do update
      set h = excluded.h, a = excluded.a, updated_at = now();
    v_saved := v_saved + 1;
  end loop;
  return json_build_object('ok', true, 'saved', v_saved, 'skipped', v_skip);
end
$$;

-- Lets a player replace their own PIN. The current PIN is checked like a login (same
-- wrong-attempt limit); the new one must be exactly 4 digits and different from the old one.
create or replace function public.change_pin(p_player text, p_pin text, p_new text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(p_new, '') !~ '^[0-9]{4}$' then
    return json_build_object('ok', false, 'error', 'bad_new');
  end if;
  if not _verify_pin(p_player, p_pin) then
    return json_build_object('ok', false, 'error', 'bad_pin');
  end if;
  if p_new = p_pin then
    return json_build_object('ok', false, 'error', 'same');
  end if;
  update players set pin_hash = crypt(p_new, gen_salt('bf')) where id = p_player;
  return json_build_object('ok', true);
end
$$;

-- The one-argument lock check from before Champions League support is no longer used.
drop function if exists public._week_locked(int);

revoke all on function public.get_state() from public;
revoke all on function public.login(text, text) from public;
revoke all on function public.save_picks(text, text, jsonb) from public;
grant execute on function public.get_state() to anon, authenticated;
grant execute on function public.login(text, text) to anon, authenticated;
grant execute on function public.save_picks(text, text, jsonb) to anon, authenticated;
revoke all on function public.change_pin(text, text, text) from public;
grant execute on function public.change_pin(text, text, text) to anon, authenticated;
