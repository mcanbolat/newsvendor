-- =====================================================================
--  Ready-made reporting queries — paste into Supabase → SQL Editor.
--  Replace OPS101 with your session code. (The SQL editor runs as admin,
--  so it sees every session.)
-- =====================================================================

-- 1. Headline results by condition (mean order vs optimal, pull-to-centre,
--    demand chasing, efficiency)
select condition, participants, q_star, mean_demand, mean_order,
       mean_pull_to_center, mean_demand_chasing, mean_efficiency_pct
from v_condition_summary
where session_code = 'OPS101';

-- 2. Does the classic pattern appear? Under-order in high-margin,
--    over-order in low-margin (both pulled toward mean demand)
select condition,
       round(avg(order_qty), 1)                          as mean_order,
       max(q_star)                                       as q_star,
       round(avg(order_qty) - max(q_star), 1)            as bias,
       round(100.0 * avg((order_qty between least(q_star, mean_demand)
                                      and greatest(q_star, mean_demand))::int), 1)
                                                         as pct_orders_between_qstar_and_mean
from v_decisions
where session_code = 'OPS101'
group by condition;

-- 3. Learning: first 10 vs last 10 rounds
select condition,
       case when round <= 10 then 'rounds 1-10'
            when round > (select n_rounds from sessions where code = 'OPS101') - 10 then 'last 10'
            else 'middle' end                            as block,
       round(avg(order_qty), 1)                          as mean_order,
       round(avg(abs(dev_from_opt)), 1)                  as mean_abs_dev
from v_decisions
where session_code = 'OPS101'
group by 1, 2
order by 1, 2;

-- 4. Demand chasing (pooled regression slope):
--    order change_t = a + b * (demand_{t-1} - order_{t-1})
--    b > 0 means students chase last period's demand
select condition,
       round(regr_slope(order_change, prev_error)::numeric, 3)     as chasing_slope,
       round(regr_intercept(order_change, prev_error)::numeric, 2) as intercept,
       round(regr_r2(order_change, prev_error)::numeric, 3)        as r2,
       regr_count(order_change, prev_error)                        as n
from v_decisions
where session_code = 'OPS101'
group by condition;

-- 5. Welch t-test inputs: mean order per student, high vs low condition
select condition, count(*) n, round(avg(mean_order), 2) mean,
       round(stddev_samp(mean_order), 2) sd
from v_participant_summary
where session_code = 'OPS101'
group by condition;

-- 6. Per-student table to share in debrief (anonymous: nickname only)
select nickname, condition, rounds, mean_order, q_star, pull_to_center,
       demand_chasing_corr, efficiency_pct, mean_response_s
from v_participant_summary
where session_code = 'OPS101'
order by condition, efficiency_pct desc;

-- 7. Attention proxy (only if the session used param_display = 'click'):
--    do students who look at prices more often order closer to optimal?
select condition,
       round(corr(mean_param_reveals, mean_abs_dev)::numeric, 3) as corr_reveals_vs_abs_dev,
       round(avg(mean_param_reveals), 2)                         as avg_reveals_per_round
from v_participant_summary
where session_code = 'OPS101'
group by condition;

-- 8. Full long-format export (Results → Export → CSV) for R / Stata / Python
select session_code, nickname, student_ref, condition, unit_cost, price, salvage,
       demand_min, demand_max, q_star, round, order_qty, demand, sales, leftover,
       shortage, profit, opt_profit, prev_demand, prev_order, order_change,
       response_ms, param_reveals, created_at
from v_decisions
where session_code = 'OPS101'
order by nickname, round;

-- Housekeeping -------------------------------------------------------
-- Remove a test player:   delete from participants where nickname = 'test' and session_id = (select id from sessions where code = 'OPS101');
-- Close a session:        update sessions set is_open = false where code = 'OPS101';
-- Delete a whole session: delete from sessions where code = 'OPS101';
