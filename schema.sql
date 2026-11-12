-- =====================================================================
--  Newsvendor Classroom Experiment — database schema (Supabase / Postgres)
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--
--  Design
--   * Demand is drawn on the SERVER when a session is created, so every
--     student in a session faces the same demand sequence and nobody can
--     peek at it from the browser.
--   * Students never touch tables directly; they call four functions
--     (join_session, resume_session, submit_order, leaderboard).
--   * The instructor logs in (Supabase Auth) and, via row-level security,
--     sees only the sessions they own.
--   * Conditions: 'high' = high-margin product (low unit cost),
--                 'low'  = low-margin product (high unit cost).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------
create table if not exists public.sessions (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique check (code ~ '^[A-Z0-9]{3,12}$'),
  title             text not null default 'Newsvendor game',
  n_rounds          int  not null default 30  check (n_rounds between 1 and 200),
  price             numeric not null default 12 check (price > 0),
  salvage           numeric not null default 0  check (salvage >= 0),
  cost_high_margin  numeric not null default 3,   -- unit cost in the HIGH-margin condition
  cost_low_margin   numeric not null default 9,   -- unit cost in the LOW-margin condition
  demand_min        int  not null default 1  check (demand_min >= 0),
  demand_max        int  not null default 300,
  assignment        text not null default 'random'
                    check (assignment in ('high','low','random')),
  param_display     text not null default 'always'
                    check (param_display in ('always','click')),
  show_leaderboard  boolean not null default true,
  is_open           boolean not null default true,
  owner             uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at        timestamptz not null default now(),
  check (demand_max > demand_min),
  check (salvage < cost_high_margin and salvage < cost_low_margin),
  check (cost_high_margin < price and cost_low_margin < price)
);

-- Demand distribution (safe to re-run on an existing database).
-- demand_min / demand_max are the support for every distribution, and orders must lie within them.
alter table public.sessions add column if not exists demand_dist text not null default 'uniform';
alter table public.sessions add column if not exists demand_mode numeric;  -- triangular: most likely value
alter table public.sessions add column if not exists demand_mean numeric;  -- normal: mean
alter table public.sessions add column if not exists demand_sd   numeric;  -- normal: standard deviation
alter table public.sessions drop constraint if exists sessions_demand_dist_chk;
alter table public.sessions add constraint sessions_demand_dist_chk check (
     demand_dist = 'uniform'
  or (demand_dist = 'triangular' and demand_mode between demand_min and demand_max)
  or (demand_dist = 'normal' and demand_sd > 0 and demand_mean between demand_min and demand_max));

-- Demand realisations, one row per round, generated automatically.
create table if not exists public.session_demand (
  session_id uuid not null references public.sessions(id) on delete cascade,
  round      int  not null,
  demand     int  not null,
  primary key (session_id, round)
);

create table if not exists public.participants (
  id          uuid primary key default gen_random_uuid(),
  token       uuid not null default gen_random_uuid(),   -- secret kept in the student's browser
  session_id  uuid not null references public.sessions(id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 1 and 40),
  student_ref text check (char_length(student_ref) <= 60),
  condition   text not null check (condition in ('high','low')),
  unit_cost   numeric not null,
  user_agent  text,
  joined_at   timestamptz not null default now(),
  finished_at timestamptz
);
create unique index if not exists participants_nick_uq
  on public.participants (session_id, lower(nickname));

create table if not exists public.decisions (
  id             bigint generated always as identity primary key,
  session_id     uuid not null references public.sessions(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  round          int  not null,
  order_qty      int  not null check (order_qty >= 0),
  demand         int  not null,
  sales          int  not null,
  leftover       int  not null,
  shortage       int  not null,
  profit         numeric not null,
  response_ms    int,          -- time from round start to submit
  param_reveals  int,          -- clicks on "show prices" (only when param_display = 'click')
  created_at     timestamptz not null default now(),
  unique (participant_id, round)
);
create index if not exists decisions_session_idx on public.decisions (session_id, round);

-- ---------------------------------------------------------------------
--  Newsvendor helpers
-- ---------------------------------------------------------------------
create or replace function public.nv_profit(q numeric, d numeric, p numeric, c numeric, s numeric)
returns numeric language sql immutable as $$
  select p * least(q, d) + s * greatest(q - d, 0) - c * q
$$;

-- Views are rebuilt below; drop them first so helper signatures can change on re-runs
drop view if exists public.v_decisions cascade;
drop function if exists public.nv_qstar(numeric, numeric, numeric, numeric, numeric);

-- Standard normal pdf, cdf (Abramowitz & Stegun 7.1.26) and inverse cdf (Acklam); error < 1e-6
create or replace function public.nv_norm_pdf(x double precision)
returns double precision language sql immutable as $$ select exp(-x * x / 2) / sqrt(2 * pi()) $$;

create or replace function public.nv_norm_cdf(x double precision)
returns double precision language plpgsql immutable as $$
declare
  z double precision := abs(x) / sqrt(2.0);
  t double precision := 1.0 / (1.0 + 0.3275911 * z);
  e double precision;
begin
  e := 1.0 - (((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t
               + 0.254829592) * t) * exp(-z * z);
  return case when x >= 0 then 0.5 * (1 + e) else 0.5 * (1 - e) end;
end $$;

create or replace function public.nv_norm_inv(p double precision)
returns double precision language plpgsql immutable as $$
declare
  q double precision; r double precision;
begin
  p := least(greatest(p, 1e-12), 1 - 1e-12);
  if p < 0.02425 then
    q := sqrt(-2 * ln(p));
    return (((((-7.784894002430293e-03 * q - 3.223964580411365e-01) * q - 2.400758277161838e+00) * q
             - 2.549732539343734e+00) * q + 4.374664141464968e+00) * q + 2.938163982698783e+00)
         / ((((7.784695709041462e-03 * q + 3.224671290700398e-01) * q + 2.445134137142996e+00) * q
             + 3.754408661907416e+00) * q + 1);
  elsif p <= 1 - 0.02425 then
    q := p - 0.5; r := q * q;
    return (((((-3.969683028665376e+01 * r + 2.209460984245205e+02) * r - 2.759285104469687e+02) * r
             + 1.383577518672690e+02) * r - 3.066479806614716e+01) * r + 2.506628277459239e+00) * q
         / (((((-5.447609879822406e+01 * r + 1.615858368580409e+02) * r - 1.556989798598866e+02) * r
             + 6.680131188771972e+01) * r - 1.328068155288572e+01) * r + 1);
  else
    return -nv_norm_inv(1 - p);
  end if;
end $$;

-- Optimal order Q* = F^-1(CR) for the session's demand distribution (normal is truncated to [min, max])
create or replace function public.nv_qstar(s public.sessions, c numeric)
returns numeric language plpgsql immutable set search_path = public as $$
declare
  cr double precision := (s.price - c) / (s.price - s.salvage);
  a  double precision := s.demand_min;
  b  double precision := s.demand_max;
  m  double precision := s.demand_mode;
  pa double precision; pb double precision; q double precision;
begin
  if s.demand_dist = 'triangular' then
    if cr <= (m - a) / (b - a) then q := a + sqrt(cr * (b - a) * (m - a));
    else q := b - sqrt((1 - cr) * (b - a) * (b - m)); end if;
  elsif s.demand_dist = 'normal' then
    pa := nv_norm_cdf((a - s.demand_mean) / s.demand_sd);
    pb := nv_norm_cdf((b - s.demand_mean) / s.demand_sd);
    q := s.demand_mean + s.demand_sd * nv_norm_inv(pa + cr * (pb - pa));
  else
    q := a + cr * (b - a);
  end if;
  return round(least(greatest(q, a), b)::numeric);
end $$;

-- Mean demand of the session's distribution (used for the pull-to-center index)
create or replace function public.nv_mean(s public.sessions)
returns numeric language plpgsql immutable set search_path = public as $$
declare al double precision; be double precision;
begin
  if s.demand_dist = 'triangular' then
    return (s.demand_min + s.demand_mode + s.demand_max) / 3.0;
  elsif s.demand_dist = 'normal' then
    al := (s.demand_min - s.demand_mean) / s.demand_sd;
    be := (s.demand_max - s.demand_mean) / s.demand_sd;
    return (s.demand_mean + s.demand_sd * (nv_norm_pdf(al) - nv_norm_pdf(be))
            / (nv_norm_cdf(be) - nv_norm_cdf(al)))::numeric;
  end if;
  return (s.demand_min + s.demand_max) / 2.0;
end $$;

-- One random demand draw (whole number within [min, max])
create or replace function public.nv_draw(s public.sessions)
returns int language plpgsql volatile set search_path = public as $$
declare
  u  double precision := random();
  a  double precision := s.demand_min;
  b  double precision := s.demand_max;
  m  double precision := s.demand_mode;
  pa double precision; pb double precision; x double precision;
begin
  if s.demand_dist = 'triangular' then
    if u < (m - a) / (b - a) then x := a + sqrt(u * (b - a) * (m - a));
    else x := b - sqrt((1 - u) * (b - a) * (b - m)); end if;
  elsif s.demand_dist = 'normal' then
    pa := nv_norm_cdf((a - s.demand_mean) / s.demand_sd);
    pb := nv_norm_cdf((b - s.demand_mean) / s.demand_sd);
    x := s.demand_mean + s.demand_sd * nv_norm_inv(pa + u * (pb - pa));
  else
    return s.demand_min + floor(u * (s.demand_max - s.demand_min + 1))::int;
  end if;
  return least(greatest(round(x)::int, s.demand_min), s.demand_max);
end $$;

-- ---------------------------------------------------------------------
--  Demand generation (on insert, or when range/rounds change before play)
-- ---------------------------------------------------------------------
create or replace function public._generate_demand()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if (new.n_rounds, new.demand_min, new.demand_max, new.demand_dist, new.demand_mode,
        new.demand_mean, new.demand_sd) is not distinct from
       (old.n_rounds, old.demand_min, old.demand_max, old.demand_dist, old.demand_mode,
        old.demand_mean, old.demand_sd) then
      return new;
    end if;
    if exists (select 1 from decisions where session_id = new.id) then
      raise exception 'Cannot change rounds or demand settings after students have played';
    end if;
    delete from session_demand where session_id = new.id;
  end if;

  insert into session_demand (session_id, round, demand)
  select new.id, g, nv_draw(new)
  from generate_series(1, new.n_rounds) g;
  return new;
end $$;

drop trigger if exists sessions_demand_trg on public.sessions;
create trigger sessions_demand_trg
  after insert or update on public.sessions
  for each row execute function public._generate_demand();

-- Parameters can't change once anyone has played (keeps data interpretable)
create or replace function public._lock_params()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from participants where session_id = old.id) and
     (new.price, new.salvage, new.cost_high_margin, new.cost_low_margin)
       is distinct from (old.price, old.salvage, old.cost_high_margin, old.cost_low_margin) then
    raise exception 'Prices and costs are locked once students have joined';
  end if;
  return new;
end $$;

drop trigger if exists sessions_lock_trg on public.sessions;
create trigger sessions_lock_trg
  before update on public.sessions
  for each row execute function public._lock_params();

-- ---------------------------------------------------------------------
--  Student-facing functions (callable with the public/anon key)
-- ---------------------------------------------------------------------
create or replace function public._participant_state(p_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'participant_id', p.id,
    'token',          p.token,
    'nickname',       p.nickname,
    'condition',      p.condition,
    'session_code',   s.code,
    'title',          s.title,
    'price',          s.price,
    'cost',           p.unit_cost,
    'salvage',        s.salvage,
    'demand_min',     s.demand_min,
    'demand_max',     s.demand_max,
    'demand_dist',    s.demand_dist,
    'demand_mode',    s.demand_mode,
    'demand_mean',    s.demand_mean,
    'demand_sd',      s.demand_sd,
    'n_rounds',       s.n_rounds,
    'param_display',  s.param_display,
    'show_leaderboard', s.show_leaderboard,
    'is_open',        s.is_open,
    'history', coalesce((
        select json_agg(json_build_object(
                 'round', d.round, 'order_qty', d.order_qty, 'demand', d.demand,
                 'sales', d.sales, 'leftover', d.leftover, 'shortage', d.shortage,
                 'profit', d.profit) order by d.round)
        from decisions d where d.participant_id = p.id), '[]'::json)
  )
  from participants p join sessions s on s.id = p.session_id
  where p.id = p_id
$$;

create or replace function public.join_session(
  p_code text, p_nickname text, p_student_ref text default null, p_user_agent text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  s    sessions;
  cond text;
  pid  uuid;
  nh   int; nl int;
begin
  select * into s from sessions where code = upper(trim(p_code));
  if not found then raise exception 'Session code not found'; end if;
  if not s.is_open then raise exception 'This session is closed'; end if;

  p_nickname := trim(coalesce(p_nickname, ''));
  if p_nickname = '' then raise exception 'Please enter a nickname'; end if;
  if exists (select 1 from participants where session_id = s.id
             and lower(nickname) = lower(p_nickname)) then
    raise exception 'That nickname is already taken in this session — please choose another';
  end if;

  if s.assignment = 'random' then
    -- balanced randomisation: fill the smaller group; coin flip on ties
    select count(*) filter (where condition = 'high'),
           count(*) filter (where condition = 'low')
      into nh, nl from participants where session_id = s.id;
    cond := case when nh < nl then 'high'
                 when nl < nh then 'low'
                 when random() < 0.5 then 'high' else 'low' end;
  else
    cond := s.assignment;
  end if;

  insert into participants (session_id, nickname, student_ref, condition, unit_cost, user_agent)
  values (s.id, p_nickname, nullif(trim(p_student_ref), ''), cond,
          case when cond = 'high' then s.cost_high_margin else s.cost_low_margin end,
          left(p_user_agent, 300))
  returning id into pid;

  return _participant_state(pid);
end $$;

create or replace function public.resume_session(p_participant uuid, p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from participants where id = p_participant and token = p_token) then
    raise exception 'Saved game not found';
  end if;
  return _participant_state(p_participant);
end $$;

create or replace function public.submit_order(
  p_participant uuid, p_token uuid, p_round int, p_qty int,
  p_response_ms int default null, p_param_reveals int default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  p participants;
  s sessions;
  v_next int; v_d int; v_sales int; v_profit numeric; v_cum numeric; v_max int;
begin
  select * into p from participants where id = p_participant and token = p_token;
  if not found then raise exception 'Invalid participant'; end if;
  select * into s from sessions where id = p.session_id;
  if not s.is_open then raise exception 'This session has been closed by the instructor'; end if;

  -- lock this participant's rows so double-clicks can't create two submissions
  perform 1 from participants where id = p.id for update;
  select coalesce(max(round), 0) + 1 into v_next from decisions where participant_id = p.id;
  if v_next > s.n_rounds then raise exception 'You have already completed all rounds'; end if;
  if p_round is distinct from v_next then
    raise exception 'Round out of sync — expected round %', v_next;
  end if;

  if p_qty is null or p_qty < s.demand_min or p_qty > s.demand_max then
    raise exception 'Order must be a whole number between % and %', s.demand_min, s.demand_max;
  end if;

  select demand into v_d from session_demand where session_id = s.id and round = v_next;
  v_sales  := least(p_qty, v_d);
  v_profit := nv_profit(p_qty, v_d, s.price, p.unit_cost, s.salvage);

  insert into decisions (session_id, participant_id, round, order_qty, demand, sales,
                         leftover, shortage, profit, response_ms, param_reveals)
  values (s.id, p.id, v_next, p_qty, v_d, v_sales, p_qty - v_sales,
          greatest(v_d - p_qty, 0), v_profit,
          case when p_response_ms between 0 and 3600000 then p_response_ms end,
          p_param_reveals);

  if v_next = s.n_rounds then
    update participants set finished_at = now() where id = p.id;
  end if;

  select sum(profit) into v_cum from decisions where participant_id = p.id;

  return json_build_object(
    'round', v_next, 'order_qty', p_qty, 'demand', v_d, 'sales', v_sales,
    'leftover', p_qty - v_sales, 'shortage', greatest(v_d - p_qty, 0),
    'profit', v_profit, 'cum_profit', v_cum, 'done', v_next = s.n_rounds);
end $$;

-- Ranked by "efficiency" WITHIN each condition: your profit ÷ the profit the optimal
-- order would have earned on the same demand sequence.
drop function if exists public.leaderboard(text);
create or replace function public.leaderboard(p_code text)
returns table (condition text, rank bigint, nickname text, rounds bigint,
               total_profit numeric, efficiency numeric)
language sql stable security definer set search_path = public as $$
  with agg as (
    select p.condition, p.nickname,
           count(d.*) as rounds,
           sum(d.profit) as total_profit,
           sum(nv_profit(nv_qstar(s, p.unit_cost), d.demand, s.price, p.unit_cost, s.salvage)) as opt_profit
    from sessions s
    join participants p on p.session_id = s.id
    join decisions d on d.participant_id = p.id
    where s.code = upper(trim(p_code)) and s.show_leaderboard
    group by p.condition, p.nickname
  )
  select condition,
         rank() over (partition by condition
                      order by case when opt_profit > 0 then total_profit / opt_profit end desc nulls last),
         nickname, rounds, round(total_profit, 2),
         case when opt_profit > 0 then round(100 * total_profit / opt_profit, 1) end
  from agg
  order by 1, 2, 3
$$;

-- Tiny function the keep-alive job calls so the free project doesn't pause
create or replace function public.ping()
returns int language sql stable security definer set search_path = public as $$ select count(*)::int from sessions where false $$;

-- ---------------------------------------------------------------------
--  Permissions & row-level security
-- ---------------------------------------------------------------------
alter table public.sessions       enable row level security;
alter table public.session_demand enable row level security;
alter table public.participants   enable row level security;
alter table public.decisions      enable row level security;

-- Students (anon) get NO direct table access — only the functions above.
revoke all on public.sessions, public.session_demand, public.participants, public.decisions from anon;

drop policy if exists sessions_owner on public.sessions;
create policy sessions_owner on public.sessions
  for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists demand_owner on public.session_demand;
create policy demand_owner on public.session_demand
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_id and s.owner = auth.uid()));

drop policy if exists participants_owner_sel on public.participants;
create policy participants_owner_sel on public.participants
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_id and s.owner = auth.uid()));
drop policy if exists participants_owner_del on public.participants;
create policy participants_owner_del on public.participants
  for delete to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_id and s.owner = auth.uid()));

drop policy if exists decisions_owner_sel on public.decisions;
create policy decisions_owner_sel on public.decisions
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_id and s.owner = auth.uid()));

revoke execute on function public._participant_state(uuid) from public, anon, authenticated;
revoke execute on function public._generate_demand() from public, anon, authenticated;
revoke execute on function public._lock_params() from public, anon, authenticated;
revoke execute on function public.nv_draw(public.sessions) from public, anon;
grant execute on function public.join_session(text, text, text, text)          to anon, authenticated;
grant execute on function public.resume_session(uuid, uuid)                     to anon, authenticated;
grant execute on function public.submit_order(uuid, uuid, int, int, int, int)   to anon, authenticated;
grant execute on function public.leaderboard(text)                              to anon, authenticated;
grant execute on function public.ping()                                         to anon, authenticated;

-- ---------------------------------------------------------------------
--  Reporting views (respect RLS: an instructor sees only their sessions)
-- ---------------------------------------------------------------------

-- One row per decision, enriched with optimal order, deviations and lags
create or replace view public.v_decisions with (security_invoker = true) as
with base as (
  select d.*, s.code as session_code, s.title, p.nickname, p.student_ref, p.condition,
         p.unit_cost, s.price, s.salvage, s.demand_dist, s.demand_min, s.demand_max,
         s.demand_mode, s.demand_mean, s.demand_sd,
         (s.price - p.unit_cost) / (s.price - s.salvage)                    as critical_ratio,
         nv_qstar(s, p.unit_cost)                                            as q_star,
         round(nv_mean(s), 2)                                                as mean_demand
  from public.decisions d
  join public.participants p on p.id = d.participant_id
  join public.sessions s     on s.id = d.session_id
)
select b.*,
       b.order_qty - b.q_star                                        as dev_from_opt,
       nv_profit(b.q_star, b.demand, b.price, b.unit_cost, b.salvage) as opt_profit,
       lag(b.demand)    over w                                       as prev_demand,
       lag(b.order_qty) over w                                       as prev_order,
       b.order_qty - lag(b.order_qty) over w                         as order_change,
       lag(b.demand) over w - lag(b.order_qty) over w                as prev_error   -- + = stocked out last round
from base b
window w as (partition by b.participant_id order by b.round);

-- One row per participant: the classic behavioural metrics
create or replace view public.v_participant_summary with (security_invoker = true) as
select session_id, session_code, participant_id, nickname, student_ref, condition,
       unit_cost, critical_ratio, q_star, mean_demand,
       count(*)                                         as rounds,
       round(avg(order_qty), 2)                         as mean_order,
       round(stddev_samp(order_qty), 2)                 as sd_order,
       round(avg(abs(dev_from_opt)), 2)                 as mean_abs_dev,
       -- 0 = orders at optimum, 1 = orders at mean demand (full pull-to-centre)
       round((avg(order_qty) - q_star) / nullif(mean_demand - q_star, 0), 3) as pull_to_center,
       -- correlation of order change with last round's (demand - order); >0 = demand chasing
       round(corr(order_change, prev_error)::numeric, 3) as demand_chasing_corr,
       round(sum(profit), 2)                            as total_profit,
       round(sum(opt_profit), 2)                        as optimal_profit,
       case when sum(opt_profit) > 0 then round(100 * sum(profit) / sum(opt_profit), 1) end as efficiency_pct,
       round(avg(response_ms) / 1000.0, 2)              as mean_response_s,
       round(avg(param_reveals), 2)                     as mean_param_reveals
from public.v_decisions
group by session_id, session_code, participant_id, nickname, student_ref, condition,
         unit_cost, critical_ratio, q_star, mean_demand;

-- Per session × condition × round (for the "average order over time" chart)
create or replace view public.v_round_summary with (security_invoker = true) as
select session_id, session_code, condition, round,
       count(*)                          as n,
       round(avg(order_qty), 2)          as mean_order,
       round(stddev_samp(order_qty), 2)  as sd_order,
       max(q_star)                       as q_star,
       max(demand)                       as demand,
       max(mean_demand)                  as mean_demand
from public.v_decisions
group by session_id, session_code, condition, round;

-- Per session × condition headline table
create or replace view public.v_condition_summary with (security_invoker = true) as
select session_id, session_code, condition,
       count(*)                                  as participants,
       max(unit_cost)                            as unit_cost,
       max(critical_ratio)                       as critical_ratio,
       max(q_star)                               as q_star,
       max(mean_demand)                          as mean_demand,
       round(avg(mean_order), 2)                 as mean_order,
       round(avg(pull_to_center), 3)             as mean_pull_to_center,
       round(avg(demand_chasing_corr), 3)        as mean_demand_chasing,
       round(avg(efficiency_pct), 1)             as mean_efficiency_pct,
       round(avg(mean_response_s), 2)            as mean_response_s
from public.v_participant_summary
group by session_id, session_code, condition;

grant select on public.v_decisions, public.v_participant_summary,
                public.v_round_summary, public.v_condition_summary to authenticated;
revoke all on public.v_decisions, public.v_participant_summary,
              public.v_round_summary, public.v_condition_summary from anon;
