# FSA Allocation Simulation (web version)

A browser version of the Excel/VBA simulation in *Flexible Spending Accounts and the Newsvendor Model:
An Experiential Exercise in Behavioral Decision-Making*. Students make 15 yearly FSA contribution decisions
on their phones or laptops. Their decisions go straight into a database, and you watch the results live.

It uses the same free stack as the newsvendor game in the folder above:

| Piece | Where it runs |
|---|---|
| `index.html`: the student simulation | GitHub Pages (`…github.io/newsvendor/fsa/`) |
| `admin.html`: the instructor dashboard | GitHub Pages, behind your Supabase login |
| `fsa_schema.sql`: tables, game logic, reporting views | Supabase, **the same project as the newsvendor game** |
| `fsa_analysis.sql` / `fsa_analysis.R` | Supabase SQL Editor / R |

**Try it first.** If `../config.js` has no keys, both pages run in demo mode. Add `?k=astute&i=yes` (or
`uninformed` / `no`) to the student link to force a condition while testing.

---

## What carries over from the Excel files

| Excel/VBA | Web version |
|---|---|
| Intro slides (`Intro Directions.pptx`) | One slide per screen, with the text from the paper's directions. The FSA limit and year, the contribution range and the number of years come from the session settings. |
| Main menu: Year, FSA Amount, last year's need, last year's contribution, historical need graph | Same screen and same fields |
| Need sequence 1200, 1100, 1400, 1300, **1900/1600**, 1400, … 1100 | Default sequence. It can be edited per session, or redrawn at random. |
| `UnfortunateEvent` form after year 5 | Same message and button. The year, the amount and the wording can be changed. |
| Astute: `FSAList` form when over-contributed (PCH, HW, SC, Forfeit) | Same categories and items, stored as PCH / HW / SC / Forfeit |
| Astute: `TaxSaveForm` when under-contributed, shortfall × 0.36 | Same text. The rate is the session's tax rate. |
| Uninformed: "Your FSA eligible healthcare spending was $X lower/higher than your contribution." | Same message |
| One `.xlsm` per condition (Astute, Uninformed, LNUE, Group 4) | One session link. Students are spread over the conditions you choose by **balanced randomisation**. |
| `OrderHistory` sheet, files emailed back and merged | Saved automatically. "Export paper-format CSV" gives the columns of `datasetforpaper.csv`. |

**Design (2×2).** Knowledge (Astute / Uninformed) × Incident (incident / none). Group numbers follow
your dataset: 1 = Astute + incident, 2 = Uninformed + incident, 3 = Astute + no incident,
4 = Uninformed + no incident. The paper's design is *Knowledge: both, Incident: everyone*, which is the default.

**Deliberate differences from the VBA, all small:**
- Contributions **must** lie within the session's range ($1,000–$2,000 by default) and be whole dollars.
  The VBA only checked that the entry was a number.
- On the leftover-funds form, the student must tick at least one box, and "forfeit" can't be combined with
  buying. The VBA allowed proceeding with nothing ticked.
- The tax message now reads "could have avoided paying" (the VBA had "avoided from paying").
- New in the data: response time per decision, time spent on the intro, and time spent on the items form.
- There is an optional end-of-game summary chart for the student (it can be turned off per session). It only
  appears after the last decision, so it can't affect the data.

## Settings you can change per session

Tax rate · minimum and maximum contribution · the yearly need sequence (any length up to 50) · the incident
year, the need in that year, and the message · the legal FSA limit and year shown in the intro ·
which cells of the 2×2 to use · whether to show the intro and the end summary.

Once a student has joined, the settings are locked so the data stay comparable. To change something,
create a new session.

## 2027 design with carryover (default for new sessions)

The **2027 design** button fills in the defaults below; **Paper's design** restores the original
settings ($1,000–$2,000, no carryover, incident $1,900).

| Setting | 2027 design | Paper's design |
|---|---|---|
| Contribution allowed | $0–$3,500 (2027 legal limit) | $1,000–$2,000 |
| Need range shown in the graph | $1,500–$3,500 | $1,000–$2,000 |
| Carryover cap | $700 (2027 limit) | none |
| Incident (year 5) | $4,000 | $1,900 |
| Benchmark | target balance y* = $2,668 | Q* = $1,360 |

**Need sequence.** 3150, 3050, 1550, 2250, 2500, 1700, 3300, 3450, 2100, 2650, 2900, 2750, 1850, 2350, 1950.
It holds one value from each fifteenth of U[$1,500, $3,500] (rounded to $50), so the realised needs match the
distribution shown in the graph. The order was chosen so that years 1–5 and years 6–15 both average $2,500, the
year-to-year correlation is about zero (−0.01), there are no runs of more than two rises or falls, and the normal need in
the incident year is the median ($2,500). The incident then raises year-5 need by $1,500, above the
contribution limit, so even a maximum contribution leaves a shortfall unless money was carried over.

**Carryover.** Money left at year end can be carried into the next year up to the cap. Astute participants
enter how much to carry (no default, so the form does not suggest an amount) and spend the rest on the
eligible-item categories or forfeit it. For Uninformed participants the plan carries over the maximum
automatically and forfeits the rest; their message says how much was carried and forfeited. Money carried
out of the final year counts as the participant's (the intro says so), so there is no end-of-game effect.

**Benchmark.** A carried-over dollar replaces a contribution dollar next year, so only leftovers above the
cap k are lost. The optimal policy is a target balance y* (carry-in + contribution) with
t·P(D > y) = (1 − t − s)·P(D < y − k), where s is the value of a dollar spent on items. For uniform need on
[a, b] and s = 0, y* = a + k + t·(b − a − k) = $2,668. The benchmark contribution is therefore
$2,668 minus the amount carried in ($1,968–$2,668), compared with $2,220 with no carryover. A simulation
of the dynamic problem confirms the formula.

**Data.** Decisions also record `carry_in`, `balance` (contribution + carry_in), `carry_out`, `items_amt`
and `forfeit_amt`, and the views add `benchmark_contribution`. Sessions created before this change keep
`carryover_cap = 0` and behave and export exactly as before.

**Display.** The decision screen adds a year tracker, a dollar field with a slider (the slider has no thumb until it is
used, so it does not anchor the amount), and, when carryover is on, the carried-in amount and a bar showing the
money in the account. A chart of the participant's own past years is optional (*show_history*, off by
default, not part of the paper's design).

---

## Setup (about 5 minutes, because the newsvendor game is already set up)

1. **Database:** in Supabase open **SQL Editor → New query**, paste the whole of `fsa/fsa_schema.sql`,
   and click **Run**. You should see "Success". This adds `fsa_` tables next to the newsvendor tables
   and doesn't touch them. The file is safe to run again.
2. **Website:** nothing to do. The pages use `../config.js` and the same GitHub Pages site.
   - Students: `https://mcanbolat.github.io/newsvendor/fsa/?code=YOURCODE`
   - You: `https://mcanbolat.github.io/newsvendor/fsa/admin.html` (same login as the newsvendor dashboard)
3. **Keep-alive:** the existing GitHub Action already pings this Supabase project every 3 days.

## Running it in class

1. Open `admin.html`, create a session (a code is suggested), and play one round yourself as `test`.
   Delete the test player with query 8 in `fsa_analysis.sql`.
2. Show the student link (as a QR code, for example). Students type only a nickname, plus an optional student ID.
3. Watch with **Live** ticked. The intro and 15 years take most students 10–15 minutes.
4. Close the session, then debrief with the chart, the Table 2-style summary and the leftover-funds chart.
5. Afterwards, click **Export paper-format CSV** and run `fsa_analysis.R`, or use the queries in `fsa_analysis.sql`.

## Data

- `fsa_sessions`: settings (needs, range, tax rate, incident, design), open or closed, owner.
- `fsa_participants`: nickname, optional student ID, knowledge, incident, group (1–4), intro time.
- `fsa_decisions`: one row per year: contribution, need, over, under, tax missed, PCH, HW, SC, Forfeit, timings.
- Views: `fsa_v_decisions` (coded like the paper: Information and Incident are Yes/No, with NCDiff lag),
  `fsa_v_cell_summary` (Table 2), and `fsa_v_participant_summary`.

The need sequence never reaches the browser before a decision is made, and students can only call the
game functions. They cannot read any table.

**Pictures:** `img/tax.svg` and `img/incident.svg` are simple original drawings that replace the stock
pictures in the Excel forms, because the repository is public. To use your own pictures, put licensed
images in `img/` with the same names.

**Research use:** get IRB approval before publishing data collected in class. Leaving the student ID blank
keeps the data anonymous.
