-- =====================================================================
--  FSA Allocation Simulation — database schema (Supabase / Postgres)
--  Web version of the Excel/VBA experiment in
--  "Flexible Spending Accounts and the Newsvendor Model".
--
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  It is safe to run again. It lives alongside the newsvendor game in the
--  same project: every object here is prefixed fsa_, so nothing collides.
--
--  Design
--   * 2×2 between-subjects design: Knowledge (astute / uninformed)
--     × Incident (year-5 medical shock / none). The instructor picks which
--     cells a session uses; students are spread over them by balanced
--     randomisation.
--   * Every number that changes over time is a session setting: tax rate,
--     contribution range, the need range shown in the graph, the yearly need
--     sequence, the incident year, amount and wording, the legal annual FSA
--     limit and the carryover cap.
--   * Carryover (carryover_cap > 0): money left in the account at year end can
--     be carried into next year up to the cap. Astute participants choose how
--     much to carry and can spend the rest on FSA-eligible items or forfeit it;
--     for Uninformed participants the plan carries over the maximum
--     automatically and the rest is forfeited. carryover_cap = 0 reproduces the
--     original design exactly.
--   * The need sequence stays on the SERVER. Students only learn a year's
--     need after they have committed their contribution for that year.
--   * Students never touch tables; they call five functions
--     (fsa_join, fsa_resume, fsa_submit, fsa_record_items, fsa_ping).
--   * The instructor logs in (Supabase Auth, the same login as the
--     newsvendor game) and, through row-level security, sees only the
--     sessions they own.
--
--  Group numbers follow the paper's dataset (datasetforpaper.csv):
--     1 = Astute + Incident        2 = Uninformed + Incident
--     3 = Astute + No incident     4 = Uninformed + No incident
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------
create table if not exists public.fsa_sessions (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique check (code ~ '^[A-Z0-9]{3,12}$'),
  title           text not null default 'FSA simulation',
  -- Need (FSA-eligible spending) in each year, for a participant WITHOUT the incident.
  -- Default (2027 design): one value from each fifteenth of U[1,500, 3,500], in a fixed
  -- order with equal means before and after year 5 (see README).
  needs           int[] not null default '{3150,3050,1550,2250,2500,1700,3300,3450,2100,2650,2900,2750,1850,2350,1950}',
  contrib_min     int  not null default 0 check (contrib_min >= 0),
  contrib_max     int  not null default 3500,
  tax_rate        numeric not null default 0.36 check (tax_rate > 0 and tax_rate < 1),
  incident_round  int  not null default 5,
  incident_need   int  not null default 4000 check (incident_need >= 0),
  incident_text   text not null default 'Uh-oh! Your son fell from his bicycle and shattered your wallet! Your FSA spending jumped to {need}!',
  knowledge_mode  text not null default 'random' check (knowledge_mode in ('random','astute','uninformed')),
  incident_mode   text not null default 'yes'    check (incident_mode  in ('random','yes','no')),
  annual_limit    int  not null default 3500,    -- legal FSA maximum, shown in the intro only
  limit_year      int  not null default 2027,
  show_intro      boolean not null default true,
  show_debrief    boolean not null default true, -- summary chart for the student after the last year
  is_open         boolean not null default true,
  owner           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now(),
  check (contrib_max > contrib_min),
  check (cardinality(needs) between 1 and 50),
  check (array_position(needs, null) is null),
  check (incident_round between 1 and cardinality(needs))
);

create table if not exists public.fsa_participants (
  id            uuid primary key default gen_random_uuid(),
  token         uuid not null default gen_random_uuid(),   -- secret kept in the student's browser
  session_id    uuid not null references public.fsa_sessions(id) on delete cascade,
  nickname      text not null check (char_length(nickname) between 1 and 40),
  student_ref   text check (char_length(student_ref) <= 60),
  knowledge     text not null check (knowledge in ('astute','uninformed')),
  incident      boolean not null,
  grp           int  not null check (grp between 1 and 4),
  user_agent    text,
  joined_at     timestamptz not null default now(),
  intro_ms      int,            -- time spent on the intro screens
  finished_at   timestamptz
);
create unique index if not exists fsa_participants_nick_uq
  on public.fsa_participants (session_id, lower(nickname));

create table if not exists public.fsa_decisions (
  id             bigint generated always as identity primary key,
  session_id     uuid not null references public.fsa_sessions(id) on delete cascade,
  participant_id uuid not null references public.fsa_participants(id) on delete cascade,
  round          int  not null,
  contribution   int  not null check (contribution >= 0),
  need           int  not null,
  over_amt       int  not null,      -- contribution − need, if positive (left in the account)
  under_amt      int  not null,      -- need − contribution, if positive (paid with after-tax money)
  tax_missed     numeric not null,   -- under_amt × tax rate
  response_ms    int,
  -- FSA Eligible Items form (Astute participants who over-contributed only); null otherwise
  pch            boolean,            -- Personal Care and Hygiene
  hw             boolean,            -- Health and Wellness
  sc             boolean,            -- Specialized Care
  forfeit        boolean,            -- "I don't want to buy anything"
  items_ms       int,
  created_at     timestamptz not null default now(),
  unique (participant_id, round)
);
create index if not exists fsa_decisions_session_idx on public.fsa_decisions (session_id, round);

-- ---------------------------------------------------------------------
--  Carryover version (added Nov 2026). Additive: sessions created before
--  this change keep carryover_cap = 0 and their original need range, so
--  they behave and export exactly as before.
-- ---------------------------------------------------------------------
alter table public.fsa_sessions add column if not exists need_min      int;
alter table public.fsa_sessions add column if not exists need_max      int;
alter table public.fsa_sessions add column if not exists carryover_cap int not null default 0;
alter table public.fsa_sessions add column if not exists show_history  boolean not null default false;
update public.fsa_sessions set need_min = contrib_min where need_min is null;
update public.fsa_sessions set need_max = contrib_max where need_max is null;
alter table public.fsa_sessions alter column need_min set default 1500;
alter table public.fsa_sessions alter column need_max set default 3500;
alter table public.fsa_sessions alter column need_min set not null;
alter table public.fsa_sessions alter column need_max set not null;
alter table public.fsa_sessions alter column carryover_cap set default 700;
-- new defaults for sessions created from now on (2027 limits)
alter table public.fsa_sessions alter column needs set default '{3150,3050,1550,2250,2500,1700,3300,3450,2100,2650,2900,2750,1850,2350,1950}';
alter table public.fsa_sessions alter column contrib_min   set default 0;
alter table public.fsa_sessions alter column contrib_max   set default 3500;
alter table public.fsa_sessions alter column incident_need set default 4000;
alter table public.fsa_sessions alter column annual_limit  set default 3500;
alter table public.fsa_sessions alter column limit_year    set default 2027;
do $$ begin
  alter table public.fsa_sessions add constraint fsa_sessions_need_range check (need_max > need_min and need_min >= 0);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.fsa_sessions add constraint fsa_sessions_carry_cap check (carryover_cap >= 0);
exception when duplicate_object then null; end $$;

alter table public.fsa_decisions add column if not exists carry_in    int not null default 0; -- carried in from last year
alter table public.fsa_decisions add column if not exists balance     int;  -- contribution + carry_in
alter table public.fsa_decisions add column if not exists carry_out   int;  -- carried into next year
alter table public.fsa_decisions add column if not exists items_amt   int;  -- leftover spent on eligible items
alter table public.fsa_decisions add column if not exists forfeit_amt int;  -- leftover forfeited
update public.fsa_decisions set balance = contribution + carry_in where balance is null;

-- ---------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------
-- Need in year r for a participant (the incident replaces that year's need)
create or replace function public.fsa_need(s public.fsa_sessions, r int, has_incident boolean)
returns int language sql immutable as $$
  select case when has_incident and r = s.incident_round then s.incident_need else s.needs[r] end
$$;

-- Newsvendor benchmark (risk-neutral, leftover items valued at 0).
--  No carryover: with p = 1, c = 1 − t and salvage 0 the critical ratio is the tax rate t,
--    so Q* = F⁻¹(t) = need_min + t·(need_max − need_min).
--  Carryover cap k: a leftover dollar within the cap replaces a contribution dollar next
--    year, so only leftovers above k are lost. The optimal policy is a target BALANCE y*
--    (contribution + carry-in) with t·P(D > y) = (1 − t)·P(D < y − k); for uniform need
--    y* = need_min + k + t·(need_max − need_min − k). The benchmark contribution in a year
--    is y* minus the amount carried in. With k = 0 this is Q*.
create or replace function public.fsa_qstar(s public.fsa_sessions)
returns numeric language sql immutable as $$
  select round(s.need_min + least(s.carryover_cap, s.need_max - s.need_min)
               + s.tax_rate * (s.need_max - s.need_min - least(s.carryover_cap, s.need_max - s.need_min)))
$$;

-- Parameters can't change once anyone has joined (keeps data interpretable)
create or replace function public._fsa_lock_params()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from fsa_participants where session_id = old.id) and
     (new.needs, new.contrib_min, new.contrib_max, new.tax_rate, new.incident_round, new.incident_need,
      new.incident_text, new.knowledge_mode, new.incident_mode, new.need_min, new.need_max, new.carryover_cap)
     is distinct from
     (old.needs, old.contrib_min, old.contrib_max, old.tax_rate, old.incident_round, old.incident_need,
      old.incident_text, old.knowledge_mode, old.incident_mode, old.need_min, old.need_max, old.carryover_cap) then
    raise exception 'Settings are locked once students have joined. Create a new session instead.';
  end if;
  return new;
end $$;

drop trigger if exists fsa_sessions_lock_trg on public.fsa_sessions;
create trigger fsa_sessions_lock_trg
  before update on public.fsa_sessions
  for each row execute function public._fsa_lock_params();

-- ---------------------------------------------------------------------
--  Student-facing functions (callable with the public/anon key)
-- ---------------------------------------------------------------------
create or replace function public._fsa_state(p_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'participant_id', p.id,
    'token',          p.token,
    'nickname',       p.nickname,
    'knowledge',      p.knowledge,
    'incident',       p.incident,
    'session_code',   s.code,
    'title',          s.title,
    'n_rounds',       cardinality(s.needs),
    'contrib_min',    s.contrib_min,
    'contrib_max',    s.contrib_max,
    'need_min',       s.need_min,
    'need_max',       s.need_max,
    'carryover_cap',  s.carryover_cap,
    'show_history',   s.show_history,
    'tax_rate',       s.tax_rate,
    'annual_limit',   s.annual_limit,
    'limit_year',     s.limit_year,
    'show_intro',     s.show_intro,
    'show_debrief',   s.show_debrief,
    'is_open',        s.is_open,
    'intro_done',     p.intro_ms is not null,
    'history', coalesce((
        select json_agg(json_build_object(
                 'round', d.round, 'contribution', d.contribution, 'need', d.need,
                 'over_amt', d.over_amt, 'under_amt', d.under_amt, 'tax_missed', d.tax_missed,
                 'carry_in', d.carry_in, 'balance', d.balance, 'carry_out', d.carry_out,
                 'items_amt', d.items_amt, 'forfeit_amt', d.forfeit_amt,
                 'items_pending', p.knowledge = 'astute' and d.over_amt > 0 and d.forfeit is null
                                  and d.pch is null)
               order by d.round)
        from fsa_decisions d where d.participant_id = p.id), '[]'::json)
  )
  from fsa_participants p join fsa_sessions s on s.id = p.session_id
  where p.id = p_id
$$;

create or replace function public.fsa_join(
  p_code text, p_nickname text, p_student_ref text default null, p_user_agent text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  s     fsa_sessions;
  cells int[];
  pick  int;
  pid   uuid;
begin
  select * into s from fsa_sessions where code = upper(trim(p_code));
  if not found then raise exception 'Session code not found'; end if;
  if not s.is_open then raise exception 'This session is closed'; end if;

  p_nickname := trim(coalesce(p_nickname, ''));
  if p_nickname = '' then raise exception 'Please enter a nickname'; end if;
  if exists (select 1 from fsa_participants where session_id = s.id
             and lower(nickname) = lower(p_nickname)) then
    raise exception 'That nickname is already taken in this session. Please choose another.';
  end if;

  -- serialise joins to this session so the balancing counts are exact
  perform 1 from fsa_sessions where id = s.id for update;

  -- cells allowed by the session settings (group numbers as in the paper's data)
  select array_agg(g) into cells from (values (1,'astute',true),(2,'uninformed',true),
                                              (3,'astute',false),(4,'uninformed',false)) v(g, k, inc)
   where (s.knowledge_mode = 'random' or s.knowledge_mode = k)
     and (s.incident_mode  = 'random' or (s.incident_mode = 'yes') = inc);

  -- balanced randomisation: a random cell among those with the fewest participants
  select c into pick
    from unnest(cells) c
    left join lateral (select count(*) n from fsa_participants
                        where session_id = s.id and grp = c) k on true
   order by k.n, random()
   limit 1;

  insert into fsa_participants (session_id, nickname, student_ref, knowledge, incident, grp, user_agent)
  values (s.id, p_nickname, nullif(trim(p_student_ref), ''),
          case when pick in (1,3) then 'astute' else 'uninformed' end,
          pick in (1,2), pick, left(p_user_agent, 300))
  returning id into pid;

  return _fsa_state(pid);
end $$;

create or replace function public.fsa_resume(p_participant uuid, p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fsa_participants where id = p_participant and token = p_token) then
    raise exception 'Saved game not found';
  end if;
  return _fsa_state(p_participant);
end $$;

-- Called once when the student leaves the intro screens (records reading time)
create or replace function public.fsa_intro_done(p_participant uuid, p_token uuid, p_ms int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update fsa_participants
     set intro_ms = coalesce(intro_ms, case when p_ms between 0 and 7200000 then p_ms else 0 end)
   where id = p_participant and token = p_token;
end $$;

create or replace function public.fsa_submit(
  p_participant uuid, p_token uuid, p_round int, p_amount int, p_response_ms int default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  p fsa_participants;
  s fsa_sessions;
  v_next int; v_n int; v_need int; v_over int; v_under int; v_tax numeric;
  v_in int; v_bal int; v_cout int; v_forf int;
begin
  select * into p from fsa_participants where id = p_participant and token = p_token;
  if not found then raise exception 'Invalid participant'; end if;
  select * into s from fsa_sessions where id = p.session_id;
  if not s.is_open then raise exception 'This session has been closed by the instructor'; end if;
  v_n := cardinality(s.needs);

  -- lock this participant so double-clicks can't create two submissions
  perform 1 from fsa_participants where id = p.id for update;
  select coalesce(max(round), 0) + 1 into v_next from fsa_decisions where participant_id = p.id;
  if v_next > v_n then raise exception 'You have already completed all years'; end if;
  if p_round is distinct from v_next then
    raise exception 'Year out of sync: expected year %', v_next;
  end if;
  if exists (select 1 from fsa_decisions where participant_id = p.id and round = v_next - 1
             and p.knowledge = 'astute' and over_amt > 0 and pch is null and forfeit is null) then
    raise exception 'Please finish last year''s leftover-funds choice first';
  end if;
  if p_amount is null or p_amount < s.contrib_min or p_amount > s.contrib_max then
    raise exception 'Contribution must be a whole-dollar amount between $% and $%', s.contrib_min, s.contrib_max;
  end if;

  -- money carried in from last year (0 without carryover)
  select coalesce(carry_out, 0) into v_in from fsa_decisions where participant_id = p.id and round = v_next - 1;
  v_in    := coalesce(v_in, 0);
  v_bal   := p_amount + v_in;
  v_need  := fsa_need(s, v_next, p.incident);
  v_over  := greatest(v_bal - v_need, 0);      -- left in the account at year end
  v_under := greatest(v_need - v_bal, 0);      -- paid with after-tax money
  v_tax   := round(v_under * s.tax_rate, 2);
  -- leftover: Astute participants decide in fsa_record_items; otherwise the plan
  -- carries over up to the cap and the rest is forfeited
  if p.knowledge = 'astute' and v_over > 0 then v_cout := null; v_forf := null;
  else v_cout := least(v_over, s.carryover_cap); v_forf := v_over - v_cout; end if;

  insert into fsa_decisions (session_id, participant_id, round, contribution, need,
                             over_amt, under_amt, tax_missed, response_ms,
                             carry_in, balance, carry_out, items_amt, forfeit_amt)
  values (s.id, p.id, v_next, p_amount, v_need, v_over, v_under, v_tax,
          case when p_response_ms between 0 and 3600000 then p_response_ms end,
          v_in, v_bal, v_cout, case when v_cout is not null then 0 end, v_forf);

  if v_next = v_n and not (p.knowledge = 'astute' and v_over > 0) then
    update fsa_participants set finished_at = now() where id = p.id;
  end if;

  return json_build_object(
    'round', v_next, 'contribution', p_amount, 'need', v_need,
    'over_amt', v_over, 'under_amt', v_under, 'tax_missed', v_tax,
    'carry_in', v_in, 'balance', v_bal, 'carry_out', v_cout, 'forfeit_amt', v_forf,
    'incident_popup', p.incident and v_next = s.incident_round,
    'incident_text', case when p.incident and v_next = s.incident_round
                          then replace(s.incident_text, '{need}', '$' || to_char(v_need, 'FM999,999,990')) end,
    'items_pending', p.knowledge = 'astute' and v_over > 0,
    'done', v_next = v_n);
end $$;

-- Leftover-funds form: Astute participants with money left at year end.
-- p_carry = amount carried into next year (0 … min(leftover, cap)); the rest is spent on
-- the ticked categories or forfeited.
drop function if exists public.fsa_record_items(uuid, uuid, int, boolean, boolean, boolean, boolean, int);
create or replace function public.fsa_record_items(
  p_participant uuid, p_token uuid, p_round int,
  p_pch boolean, p_hw boolean, p_sc boolean, p_forfeit boolean, p_ms int default null, p_carry int default 0)
returns json language plpgsql security definer set search_path = public as $$
declare
  p fsa_participants;
  d fsa_decisions;
  v_n int; v_cap int; v_carry int; v_rest int; v_buy boolean;
begin
  select * into p from fsa_participants where id = p_participant and token = p_token;
  if not found then raise exception 'Invalid participant'; end if;
  select * into d from fsa_decisions where participant_id = p.id and round = p_round for update;
  if not found then raise exception 'No contribution recorded for year %', p_round; end if;
  if p.knowledge <> 'astute' or d.over_amt <= 0 then raise exception 'No leftover funds to allocate this year'; end if;
  if d.pch is not null or d.forfeit is not null then return json_build_object('ok', true); end if;  -- already saved
  select cardinality(s.needs), s.carryover_cap into v_n, v_cap from fsa_sessions s where s.id = p.session_id;
  v_carry := coalesce(p_carry, 0);
  if v_carry < 0 or v_carry > least(d.over_amt, v_cap) then
    raise exception 'You can carry over between $0 and $%', least(d.over_amt, v_cap);
  end if;
  v_rest := d.over_amt - v_carry;
  v_buy  := coalesce(p_pch,false) or coalesce(p_hw,false) or coalesce(p_sc,false);
  if v_rest > 0 and not (v_buy or coalesce(p_forfeit,false)) then
    raise exception 'Choose at least one category, or tick the box to forfeit';
  end if;
  if v_buy and coalesce(p_forfeit,false) then raise exception 'Choose categories or forfeit, not both'; end if;

  update fsa_decisions
     set pch = coalesce(p_pch,false) and v_rest > 0, hw = coalesce(p_hw,false) and v_rest > 0,
         sc = coalesce(p_sc,false) and v_rest > 0,
         forfeit = coalesce(p_forfeit,false) and v_rest > 0,
         carry_out = v_carry,
         items_amt = case when v_buy and v_rest > 0 then v_rest else 0 end,
         forfeit_amt = case when v_buy then 0 else v_rest end,
         items_ms = case when p_ms between 0 and 3600000 then p_ms end
   where id = d.id;

  if p_round = v_n then update fsa_participants set finished_at = coalesce(finished_at, now()) where id = p.id; end if;
  return json_build_object('ok', true);
end $$;

-- Keep-alive for the free tier (the newsvendor repo's GitHub Action calls ping(); this one is spare)
create or replace function public.fsa_ping()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from fsa_sessions where false
$$;

-- ---------------------------------------------------------------------
--  Permissions & row-level security
-- ---------------------------------------------------------------------
alter table public.fsa_sessions     enable row level security;
alter table public.fsa_participants enable row level security;
alter table public.fsa_decisions    enable row level security;

-- Students (anon) get NO direct table access, only the functions above.
revoke all on public.fsa_sessions, public.fsa_participants, public.fsa_decisions from anon;

drop policy if exists fsa_sessions_owner on public.fsa_sessions;
create policy fsa_sessions_owner on public.fsa_sessions
  for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists fsa_participants_owner_sel on public.fsa_participants;
create policy fsa_participants_owner_sel on public.fsa_participants
  for select to authenticated
  using (exists (select 1 from public.fsa_sessions s where s.id = session_id and s.owner = auth.uid()));
drop policy if exists fsa_participants_owner_del on public.fsa_participants;
create policy fsa_participants_owner_del on public.fsa_participants
  for delete to authenticated
  using (exists (select 1 from public.fsa_sessions s where s.id = session_id and s.owner = auth.uid()));

drop policy if exists fsa_decisions_owner_sel on public.fsa_decisions;
create policy fsa_decisions_owner_sel on public.fsa_decisions
  for select to authenticated
  using (exists (select 1 from public.fsa_sessions s where s.id = session_id and s.owner = auth.uid()));

revoke execute on function public._fsa_state(uuid) from public, anon, authenticated;
revoke execute on function public._fsa_lock_params() from public, anon, authenticated;
grant execute on function public.fsa_join(text, text, text, text)                               to anon, authenticated;
grant execute on function public.fsa_resume(uuid, uuid)                                          to anon, authenticated;
grant execute on function public.fsa_intro_done(uuid, uuid, int)                                 to anon, authenticated;
grant execute on function public.fsa_submit(uuid, uuid, int, int, int)                           to anon, authenticated;
grant execute on function public.fsa_record_items(uuid, uuid, int, boolean, boolean, boolean, boolean, int, int) to anon, authenticated;
grant execute on function public.fsa_ping()                                                      to anon, authenticated;

-- ---------------------------------------------------------------------
--  Reporting views (respect RLS: an instructor sees only their sessions)
-- ---------------------------------------------------------------------

-- One row per decision, coded like the paper's dataset plus extra columns.
--   information = 'Yes' for Astute, 'No' for Uninformed
--   incident    = 'Yes' for years AFTER the incident in the incident groups (the paper's coding:
--                 periods 6–15 = Yes); always 'No' in the no-incident groups
--   ncdiff_lag  = need − contribution in the previous year (NCDiff_(i−1) in Table 4)
drop view if exists public.fsa_v_decisions cascade;
create view public.fsa_v_decisions with (security_invoker = true) as
select d.session_id, s.code as session_code, d.participant_id, p.nickname, p.student_ref,
       p.grp, p.knowledge, p.incident as incident_group,
       case when p.knowledge = 'astute' then 'Yes' else 'No' end                          as information,
       case when p.incident and d.round > s.incident_round then 'Yes' else 'No' end       as incident,
       d.round as period, d.need, d.contribution, d.carry_in, d.balance,
       d.over_amt, d.under_amt, d.tax_missed,
       d.carry_out, d.items_amt, d.forfeit_amt,
       d.pch::int as pch, d.hw::int as hw, d.sc::int as sc, d.forfeit::int as forfeit,
       s.tax_rate, s.contrib_min, s.contrib_max, s.need_min, s.need_max, s.carryover_cap,
       s.incident_round, fsa_qstar(s) as q_star,
       greatest(s.contrib_min, least(s.contrib_max, fsa_qstar(s) - d.carry_in))        as benchmark_contribution,
       d.response_ms, d.items_ms, d.created_at,
       lag(d.need - d.contribution) over w                                                as ncdiff_lag,
       d.contribution - lag(d.contribution) over w                                        as contribution_change
from public.fsa_decisions d
join public.fsa_participants p on p.id = d.participant_id
join public.fsa_sessions s     on s.id = d.session_id
window w as (partition by d.participant_id order by d.round);

-- Table 2 of the paper: mean / SD / n by Knowledge × before/after the incident year
create view public.fsa_v_cell_summary with (security_invoker = true) as
select session_id, session_code, grp, knowledge, incident_group,
       case when period <= incident_round then 'before (years 1-' || incident_round || ')'
            else 'after' end                                   as phase,
       count(distinct participant_id)                          as participants,
       count(*)                                                as n,
       round(avg(contribution), 2)                             as mean_contribution,
       round(stddev_samp(contribution), 2)                     as sd_contribution,
       max(q_star)                                             as q_star
from public.fsa_v_decisions
group by session_id, session_code, grp, knowledge, incident_group,
         case when period <= incident_round then 'before (years 1-' || incident_round || ')' else 'after' end;

-- One row per participant
create view public.fsa_v_participant_summary with (security_invoker = true) as
select session_id, session_code, participant_id, nickname, student_ref, grp, knowledge, incident_group,
       count(*)                                      as years,
       round(avg(contribution), 2)                   as mean_contribution,
       round(stddev_samp(contribution), 2)           as sd_contribution,
       sum(over_amt)                                 as total_left_over,
       sum(under_amt)                                as total_uncovered,
       round(sum(tax_missed), 2)                     as total_tax_missed,
       sum(case when forfeit = 1 then over_amt else 0 end) as total_forfeited_astute,
       sum(coalesce(carry_out, 0))                   as total_carried,
       sum(coalesce(items_amt, 0))                   as total_items,
       sum(coalesce(forfeit_amt, case when forfeit = 1 then over_amt else 0 end)) as total_forfeited,
       round(avg(response_ms) / 1000.0, 2)           as mean_response_s
from public.fsa_v_decisions
group by session_id, session_code, participant_id, nickname, student_ref, grp, knowledge, incident_group;

revoke all on public.fsa_v_decisions, public.fsa_v_cell_summary, public.fsa_v_participant_summary from anon;
