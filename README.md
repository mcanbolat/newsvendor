# The Newsvendor Game: a classroom experiment

This is a web version of the classic newsvendor experiment (Schweitzer & Cachon, 2000) for use in class.
Students play on their phones or laptops. You watch the results come in live, show them to the class,
and export the data or query it with SQL.

| Piece | Where it runs | Cost / ads |
|---|---|---|
| `index.html`: the student game | GitHub Pages (static hosting) | Free, no ads |
| `admin.html`: the instructor dashboard | GitHub Pages, behind a login | Free, no ads |
| `schema.sql`: tables, game logic and reporting views | Supabase (hosted Postgres) | Free tier, no ads |
| `analysis.sql`: ready-made reporting queries | Supabase SQL Editor | n/a |

> **Also in this repository:** [`fsa/`](fsa/README.md) — the FSA allocation simulation (Flexible Spending
> Accounts and the Newsvendor Model), a web version of the Excel/VBA experiment. It shares this site, `config.js`
> and Supabase project; run `fsa/fsa_schema.sql` once to add its tables.

**Try it first, without any setup.** Open `index.html` or `admin.html` straight from the folder. Without keys in
`config.js`, both pages run in **demo mode**: the game works but nothing is saved, and the dashboard
shows a simulated class.

---

## How the experiment works

- Each round a student picks an order quantity Q, then sees demand D, how many units sold, and the profit:
  `profit = p·min(Q,D) + s·max(Q−D,0) − c·Q`.
- Each session uses one of three **demand distributions**, chosen when you create it:
  - **uniform**: every whole number from min to max is equally likely;
  - **normal**: you set the mean and SD, and draws are truncated to [min, max]. The form suggests mean ± 3 SD as the range;
  - **triangular**: you set min, the most likely value and max.

  Students see a plain-language description and a sketch of the shape. Q* and mean demand are calculated with
  the formula for the chosen distribution.
- Demand is drawn **on the server** when you create the session, so every student in the session faces the
  **same demand sequence**, and nobody can peek at it from the browser.
- **Orders are limited to the demand range** [min, max]. The browser checks this, and the server enforces it.
- There are two conditions. **High margin** uses a low unit cost (default c = 3, Q* = 225) and **low margin**
  uses a high unit cost (default c = 9, Q* = 76), with p = 12, s = 0 and demand U[1, 300]. These are the
  parameters from Schweitzer & Cachon (2000). Students can be split between the conditions by balanced
  randomisation, or all put in one condition.
- **Prices hidden until clicked** (optional): the price, cost and salvage value stay hidden until the student clicks
  to show them, and each click is logged per round. This gives a cheap measure of attention.
- Response time is recorded for every decision.
- If a student refreshes the page or their phone sleeps, they pick up where they left off.
- At the end, students see a leaderboard of the players who had the same costs. It ranks by **efficiency**, which is
  profit as a % of what Q* would have earned on the same demand.

**What the dashboard shows:** the mean order per round for each condition, plotted against Q* and mean demand;
pull-to-centre (0 means ordering at Q*, 1 means ordering at mean demand); demand chasing (the correlation between a
student's change in order and last round's demand minus order); efficiency; and a histogram of each student's
mean order. You can export all decisions or a per-student table as CSV.

---

## Setup (about 20 minutes, done once)

### 1. Create the database (Supabase)
1. Sign up at **supabase.com** (free, no credit card) and click **New project**. Pick a region close to you
   and save the database password somewhere safe.
2. Go to **SQL Editor → New query**, paste the whole of `schema.sql`, and click **Run**.
   You should see "Success". The file is safe to run again later.
3. Create your instructor login: **Authentication → Users → Add user → Create new user**.
   Enter your email and a password, and tick **Auto Confirm User**.
4. Turn off public sign-ups so that only you can log in: **Authentication → Sign In / Providers**,
   then switch off **Allow new users to sign up**.
5. Copy your keys: **Project Settings → API** (or the **Connect** button). You need the **Project URL** and
   the **anon** key or the **publishable** key (`sb_publishable_…`).
   ⚠️ Never use the `service_role` key or the secret key on the website.

### 2. Connect the website
Open `config.js` and paste in the two values:
```js
window.NV_CONFIG = {
  SUPABASE_URL: "https://abcdefgh.supabase.co",
  SUPABASE_KEY: "eyJhbGciOi…  (or sb_publishable_…)"
};
```
The anon/publishable key is meant to be public. Row-level security means students can only call the four
game functions. They cannot read or change any table.

### 3. Publish the site (GitHub Pages)
1. Create a **public** repository on github.com, for example `newsvendor`.
2. Upload every file in this folder, including `vendor/` and `.github/`, either with **Add file → Upload files**
   or with `git push`.
3. Go to **Settings → Pages → Build and deployment**, choose **Deploy from a branch**, then `main` and `/ (root)`. Save.
4. After about a minute your site is live:
   - Students: `https://YOUR-USERNAME.github.io/newsvendor/`
   - You: `https://YOUR-USERNAME.github.io/newsvendor/admin.html`

Netlify Drop and Cloudflare Pages work as well: drag the folder in. Both are free and ad-free.

### 4. Keep the free database awake
Supabase pauses free projects after about a week with no activity. The included GitHub Action pings the
database every 3 days so this doesn't happen:
**repo Settings → Secrets and variables → Actions → New repository secret.** Add `SUPABASE_URL` and
`SUPABASE_KEY` with the same values as in `config.js`. Then open the **Actions** tab, enable workflows, and run
**Keep Supabase awake** once by hand to check it works.
If the project gets paused anyway, open the Supabase dashboard and click **Restore**. Your data is kept.

---

## Running it in class
1. **Before class:** open `admin.html`, sign in, and create a session. A code is suggested for you; the form
   shows Q* for both conditions as you edit the parameters. Play one round yourself using a nickname such as `test`,
   then delete it (see the end of `analysis.sql`).
2. **In class:** put the student link up on the screen. It includes `?code=…`, so students only type a nickname.
   Turning the link into a QR code makes joining from phones fast.
3. **While students play:** keep the dashboard open with **Live** ticked. 30 rounds take most students 8–12 minutes.
4. **At the end:** click **Close session** so no more orders come in. Show the chart and explain Q* using the
   debrief box, then reveal the leaderboard.
5. **Afterwards:** use **Export all decisions CSV**, or run the queries in `analysis.sql` in Supabase's
   SQL Editor (pull-to-centre, the demand-chasing regression, first vs last 10 rounds, the attention proxy, and so on).

### Variations to try
- **Within-subject:** create two sessions, one high-margin only and one low-margin only, and run them back to back.
- **Salvage value:** set a positive salvage value so you can test whether students take it into account.
- **Attention:** set *Price/cost display* to *Hidden until clicked*. Then compare the number of clicks with how far
  orders are from Q* (query 7 in `analysis.sql`).

---

## Data model (short version)
- `sessions`: one row per class run: parameters, open/closed, owner.
- `session_demand`: the demand drawn for each round. Students can't see it.
- `participants`: nickname, optional student ID, condition, unit cost.
- `decisions`: one row per round: order, demand, sales, leftover, shortage, profit, response time, clicks to show prices.
- Views: `v_decisions` (adds Q*, deviation, lags and the profit Q* would have earned), `v_participant_summary`,
  `v_round_summary`, `v_condition_summary`.

The free tier's 500 MB database holds millions of decisions, far more than you need for many semesters of classes.

**Research use:** if you plan to publish data collected in class, get IRB approval first. Leaving the
student ID field blank keeps the data anonymous.
