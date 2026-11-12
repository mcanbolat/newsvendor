-- =====================================================================
--  FSA simulation: ready-made reporting queries for Supabase → SQL Editor.
--  Replace FSA101 with your session code. (The SQL editor runs as admin,
--  so it sees every session.)
-- =====================================================================

-- 1. Table 2 of the paper: mean, SD and n by group, before/after the incident year
select grp, knowledge, incident_group, phase, participants, n, mean_contribution, sd_contribution, q_star
from fsa_v_cell_summary
where session_code = 'FSA101'
order by grp, phase desc;

-- 2. Data in the exact layout of Results/datasetforpaper.csv (copy the result
--    into a CSV, or use "Export paper-format CSV" on the dashboard)
select dense_rank() over (order by p.joined_at, p.id) as "ID",
       v.grp as "Group", v.period as "Period", v.need as "Need", v.contribution as "Contribution",
       v.pch as "PCH", v.hw as "HW", v.sc as "SC", v.forfeit as "Forfeit",
       v.information as "Information", v.incident as "Incident",
       case when v.incident_group then 'Yes' else 'No' end as "IncidentGroup"
from fsa_v_decisions v
join fsa_participants p on p.id = v.participant_id
where v.session_code = 'FSA101'
order by 1, 3;

-- 3. Knowledge effect: mean contribution, Astute vs Uninformed
select information, count(distinct participant_id) as participants,
       round(avg(contribution), 1) as mean_contribution, max(q_star) as q_star
from fsa_v_decisions
where session_code = 'FSA101'
group by information;

-- 4. Incident effect as difference-in-differences: change after the incident
--    year in the incident groups minus the same change in the no-incident groups
with m as (
  select incident_group, period > incident_round as post, avg(contribution) as mean_c
  from fsa_v_decisions where session_code = 'FSA101'
  group by 1, 2)
select round(  (select mean_c from m where incident_group and post)     - (select mean_c from m where incident_group and not post)
             - ((select mean_c from m where not incident_group and post) - (select mean_c from m where not incident_group and not post)), 1)
       as diff_in_diff;

-- 5. Do students react to last year's outcome? (Table 4: NCDiff_(i−1) = need − contribution last year)
select regr_slope(contribution_change, ncdiff_lag) as slope,
       corr(contribution_change, ncdiff_lag)       as r,
       count(*)                                    as n
from fsa_v_decisions
where session_code = 'FSA101' and ncdiff_lag is not null;

-- 6. Figure 6: what Astute students did with leftover funds
select count(*) as forms,
       round(100.0 * avg(pch), 1) as pct_personal_care,
       round(100.0 * avg(hw), 1)  as pct_health_wellness,
       round(100.0 * avg(sc), 1)  as pct_specialized_care,
       round(100.0 * avg(forfeit), 1) as pct_forfeit
from fsa_v_decisions
where session_code = 'FSA101' and pch is not null;

-- 7. Per-student summary
select * from fsa_v_participant_summary where session_code = 'FSA101' order by grp, nickname;

-- 8. Remove test players (e.g. your own trial run named "test")
-- delete from fsa_participants
--  where lower(nickname) = 'test'
--    and session_id = (select id from fsa_sessions where code = 'FSA101');
