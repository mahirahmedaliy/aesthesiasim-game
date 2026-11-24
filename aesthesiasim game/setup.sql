-- =====================================================================
-- AesthesiaSim — Supabase setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run more than once.
-- =====================================================================

-- ---------- 1. PLAYER PROFILES ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text,
  display_name  text,
  role          text,              -- e.g. student, intern, resident, anaesthetist
  country       text,
  is_admin      boolean not null default false,
  created_at    timestamptz not null default now(),
  last_seen     timestamptz not null default now()
);

-- ---------- 2. FINISHED CASES ----------
create table if not exists public.sim_games (
  id            bigint generated always as identity primary key,
  user_id       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  case_id       text not null,
  case_name     text,
  difficulty    text not null check (difficulty in ('student','resident','consultant')),
  score         integer not null default 0,
  grade         text,
  survived      boolean not null,
  duration_s    integer,
  min_spo2      integer,
  min_map       integer,
  resilience    integer,
  hints_used    integer default 0,
  events        text[] default '{}',   -- surprise events that happened
  mistakes      text[] default '{}',   -- mistake codes, e.g. 'awareness', 'hypoxia'
  good          jsonb default '[]',     -- "what went well" lines
  bad           jsonb default '[]',     -- "what to improve" lines
  app_version   text,
  created_at    timestamptz not null default now()
);

create index if not exists sim_games_user_idx    on public.sim_games(user_id);
create index if not exists sim_games_created_idx on public.sim_games(created_at desc);
create index if not exists sim_games_case_idx    on public.sim_games(case_id, difficulty);

-- ---------- 3. ADMIN CHECK ----------
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

-- ---------- 4. AUTO-CREATE A PROFILE ON SIGN-UP ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(
      nullif(new.raw_user_meta_data->>'display_name', ''),
      nullif(new.raw_user_meta_data->>'full_name', ''),
      split_part(new.email, '@', 1)
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 5. SECURITY (Row Level Security) ----------
alter table public.profiles  enable row level security;
alter table public.sim_games enable row level security;

-- Nobody who isn't logged in can touch the tables directly
revoke all on public.profiles, public.sim_games from anon;

-- Logged-in players: limited permissions; they can NEVER make themselves admin
revoke all on public.profiles from authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, role, country, last_seen) on public.profiles to authenticated;

revoke all on public.sim_games from authenticated;
grant select, insert on public.sim_games to authenticated;
grant delete on public.sim_games to authenticated;  -- only admins pass the policy below

-- profiles policies
drop policy if exists "profiles: read own or admin" on public.profiles;
create policy "profiles: read own or admin" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- sim_games policies
drop policy if exists "games: read own or admin" on public.sim_games;
create policy "games: read own or admin" on public.sim_games
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "games: insert own" on public.sim_games;
create policy "games: insert own" on public.sim_games
  for insert to authenticated
  with check (user_id = auth.uid() and score between 0 and 5000);

drop policy if exists "games: admin delete" on public.sim_games;
create policy "games: admin delete" on public.sim_games
  for delete to authenticated
  using (public.is_admin());

-- ---------- 6. PUBLIC LEADERBOARD (names + scores only, no emails) ----------
create or replace function public.get_leaderboard(
  p_case text default null,
  p_difficulty text default null,
  p_limit integer default 20
)
returns table (rank bigint, display_name text, case_id text, difficulty text, best_score integer, played_at timestamptz)
language sql stable security definer
set search_path = ''
as $$
  with best as (
    select distinct on (g.user_id, g.case_id, g.difficulty)
           g.user_id, g.case_id, g.difficulty, g.score, g.created_at
    from public.sim_games g
    where g.survived
      and (p_case is null or g.case_id = p_case)
      and (p_difficulty is null or g.difficulty = p_difficulty)
    order by g.user_id, g.case_id, g.difficulty, g.score desc, g.created_at
  )
  select row_number() over (order by b.score desc, b.created_at) as rank,
         coalesce(p.display_name, 'Anonymous'), b.case_id, b.difficulty, b.score, b.created_at
  from best b
  join public.profiles p on p.id = b.user_id
  order by b.score desc, b.created_at
  limit least(greatest(p_limit, 1), 100);
$$;

-- ---------- 7. ADMIN DASHBOARD DATA (admins only) ----------
create or replace function public.admin_overview()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  select jsonb_build_object(
    'players_total',   (select count(*) from public.profiles),
    'players_today',   (select count(*) from public.profiles where created_at >= date_trunc('day', now())),
    'players_7d',      (select count(*) from public.profiles where created_at >= now() - interval '7 days'),
    'active_7d',       (select count(distinct user_id) from public.sim_games where created_at >= now() - interval '7 days'),
    'games_total',     (select count(*) from public.sim_games),
    'games_today',     (select count(*) from public.sim_games where created_at >= date_trunc('day', now())),
    'survival_rate',   (select round(100.0 * avg(case when survived then 1 else 0 end), 1) from public.sim_games),
    'avg_score',       (select round(avg(score)) from public.sim_games),
    'by_case', coalesce((
        select jsonb_agg(x order by x.plays desc) from (
          select case_id, max(case_name) as case_name, count(*) as plays,
                 sum(case when survived then 0 else 1 end) as deaths,
                 round(avg(score)) as avg_score, max(score) as best_score
          from public.sim_games group by case_id
        ) x), '[]'::jsonb),
    'by_difficulty', coalesce((
        select jsonb_agg(x) from (
          select difficulty, count(*) as plays,
                 round(100.0 * avg(case when survived then 1 else 0 end), 1) as survival_rate,
                 round(avg(score)) as avg_score
          from public.sim_games group by difficulty
        ) x), '[]'::jsonb),
    'top_mistakes', coalesce((
        select jsonb_agg(x order by x.n desc) from (
          select m as mistake, count(*) as n
          from public.sim_games, unnest(mistakes) as m
          group by m order by count(*) desc limit 15
        ) x), '[]'::jsonb),
    'games_per_day', coalesce((
        select jsonb_agg(x order by x.day) from (
          select date_trunc('day', created_at)::date as day, count(*) as games, count(distinct user_id) as players
          from public.sim_games where created_at >= now() - interval '30 days'
          group by 1
        ) x), '[]'::jsonb),
    'signups_per_day', coalesce((
        select jsonb_agg(x order by x.day) from (
          select date_trunc('day', created_at)::date as day, count(*) as signups
          from public.profiles where created_at >= now() - interval '30 days'
          group by 1
        ) x), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

-- Admin: list of players with their stats
create or replace function public.admin_players(p_limit integer default 200)
returns table (id uuid, email text, display_name text, role text, country text, created_at timestamptz,
               last_seen timestamptz, games bigint, survived bigint, best_score integer, last_game timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  return query
    select p.id, p.email, p.display_name, p.role, p.country, p.created_at, p.last_seen,
           count(g.id), count(g.id) filter (where g.survived), max(g.score), max(g.created_at)
    from public.profiles p
    left join public.sim_games g on g.user_id = p.id
    group by p.id
    order by max(g.created_at) desc nulls last, p.created_at desc
    limit least(greatest(p_limit, 1), 1000);
end;
$$;

-- Function permissions
revoke all on function public.admin_overview() from public, anon;
revoke all on function public.admin_players(integer) from public, anon;
grant execute on function public.admin_overview() to authenticated;
grant execute on function public.admin_players(integer) to authenticated;
grant execute on function public.get_leaderboard(text, text, integer) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;

-- =====================================================================
-- AFTER you sign up in the game with your own email, run this ONE line
-- (change the email) to make yourself the admin:
--
--   update public.profiles set is_admin = true where email = 'you@example.com';
-- =====================================================================
