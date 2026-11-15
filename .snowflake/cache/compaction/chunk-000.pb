
â3
dashboard/streamlit_app.pyæ2"""ETF 12-1 Momentum - PoC dashboard.

Reads ONLY pipeline output tables and the pipeline run log in
ETF_MOMENTUM_POC.PIPELINE. No calculations beyond formatting.
"""

import os

import pandas as pd
import streamlit as st

DB = "ETF_MOMENTUM_POC.PIPELINE"

st.set_page_config(page_title="ETF 12-1 Momentum", layout="wide")

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))


@st.cache_data(ttl=300, show_spinner=False)
def q(sql: str) -> pd.DataFrame:
    return conn.query(sql, ttl=0)


def clear_cache() -> None:
    q.clear()


head_l, head_r = st.columns([5, 1])
head_l.title("ETF 12-1 Momentum")
head_l.caption(
    "Top-16 equal-weight momentum vs 49-ETF equal-weight benchmark. "
    "Source: MOCK CapIQ XpressFeed (synthetic prices) - replace with SPGLOBAL.XPRESSFEED."
)
head_r.button("Refresh", on_click=clear_cache, use_container_width=True)

with st.spinner("Loading pipeline tables..."):
    perf = q(f"""
        SELECT PORTFOLIO, TOTAL_RETURN, ANN_RETURN, ANN_VOL, MAX_DRAWDOWN, N_MONTHS, FIRST_MONTH, LAST_MONTH
        FROM {DB}.PERF_SUMMARY""")
    growth = q(f"SELECT MONTH_END, PORTFOLIO, VALUE FROM {DB}.GROWTH ORDER BY MONTH_END")
    holdings = q(f"""
        SELECT h.MONTH_END, h.TICKER, u.GROUP_NAME, s.MOM_12_1, s.RANK, h.WEIGHT
        FROM {DB}.HOLDINGS h
        JOIN {DB}.SIGNAL s ON s.TICKER = h.TICKER AND s.MONTH_END = h.MONTH_END
        LEFT JOIN {DB}.UNIVERSE u ON u.TICKER = h.TICKER
        WHERE h.PORTFOLIO = 'MOMENTUM'
          AND h.MONTH_END = (SELECT MAX(MONTH_END) FROM {DB}.HOLDINGS)
        ORDER BY s.RANK, h.TICKER""")
    last_run = q(f"""
        SELECT RUN_ID, STATUS, STARTED_AT, ENDED_AT, CODE_VERSION, DATA_AS_OF,
               PARAMS:n_held::INT AS N_HELD, PARAMS:lookback_months::INT AS LOOKBACK,
               PARAMS:skip_months::INT AS SKIP, PARAMS:start_stage::INT AS START_STAGE
        FROM {DB}.PIPELINE_RUNS ORDER BY STARTED_AT DESC LIMIT 1""")
    stages = q(f"""
        SELECT s.STAGE_NO, s.STAGE, s.STATUS, s.ENDED_AT,
               DATEDIFF('second', s.STARTED_AT, s.ENDED_AT) AS SECONDS,
               s.ROW_COUNTS, s.CODE_SHA256, COALESCE(s.ERROR_MESSAGE, s.MESSAGE) AS DETAIL
        FROM {DB}.STAGE_RUNS s
        WHERE s.RUN_ID = (SELECT RUN_ID FROM {DB}.PIPELINE_RUNS ORDER BY STARTED_AT DESC LIMIT 1)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY s.STAGE_NO ORDER BY s.ENDED_AT DESC) = 1
        ORDER BY s.STAGE_NO""")
    history = q(f"""
        SELECT r.STARTED_AT, r.STATUS, r.CODE_VERSION,
               r.PARAMS:n_held::INT AS N_HELD, r.PARAMS:start_stage::INT AS START_STAGE,
               DATEDIFF('second', r.STARTED_AT, r.ENDED_AT) AS SECONDS,
               (SELECT LISTAGG(DISTINCT STAGE, ', ') FROM {DB}.STAGE_RUNS s
                 WHERE s.RUN_ID = r.RUN_ID AND s.STATUS = 'FAILED') AS FAILED_STAGE,
               r.RUN_ID
        FROM {DB}.PIPELINE_RUNS r ORDER BY r.STARTED_AT DESC LIMIT 15""")

# ---------------------------------------------------------------- Panel 1
st.subheader("1 ¬∑ Summary")
if perf.empty:
    st.info("PERF_SUMMARY is empty - run the pipeline.")
else:
    p = perf.set_index("PORTFOLIO")
    cols = st.columns(2)
    for col, name in zip(cols, ["MOMENTUM", "BENCHMARK"]):
        if name not in p.index:
            continue
        r = p.loc[name]
        with col.container(border=True):
            st.markdown(f"**{name}**  \n{r.FIRST_MONTH} ‚Üí {r.LAST_MONTH} ¬∑ {int(r.N_MONTHS)} months")
            a, b, c, d = st.columns(4)
            a.metric("Total return", f"{r.TOTAL_RETURN:.1%}")
            b.metric("Ann. return", f"{r.ANN_RETURN:.1%}")
            c.metric("Ann. volatility", f"{r.ANN_VOL:.1%}")
            d.metric("Max drawdown", f"{r.MAX_DRAWDOWN:.1%}")

left, right = st.columns([3, 2])

# ---------------------------------------------------------------- Panel 2
with left:
    st.subheader("2 ¬∑ Growth of $1")
    if growth.empty:
        st.info("GROWTH is empty.")
    else:
        g = growth.pivot(index="MONTH_END", columns="PORTFOLIO", values="VALUE")
        st.line_chart(g, height=380)

# ---------------------------------------------------------------- Panel 3
with right:
    if holdings.empty:
        st.subheader("3 ¬∑ Current holdings")
        st.info("No holdings.")
    else:
        formed = holdings["MONTH_END"].iloc[0]
        hold_month = (pd.Timestamp(formed) + pd.offsets.MonthEnd(1)).strftime("%B %Y")
        st.subheader(f"3 ¬∑ Current holdings ({len(holdings)})")
        st.caption(f"Signal formed {formed} ¬∑ held through {hold_month}")
        st.dataframe(
            holdings[["RANK", "TICKER", "GROUP_NAME", "MOM_12_1", "WEIGHT"]],
            hide_index=True,
            use_container_width=True,
            height=380,
            column_config={
                "MOM_12_1": st.column_config.NumberColumn("12-1 momentum", format="percent"),
                "WEIGHT": st.column_config.NumberColumn("Weight", format="percent"),
                "GROUP_NAME": "Group",
            },
        )

# ---------------------------------------------------------------- Panel 4
st.subheader("4 ¬∑ Pipeline status")
if last_run.empty:
    st.info("No pipeline runs recorded yet.")
else:
    lr = last_run.iloc[0]
    ok = lr.STATUS == "SUCCEEDED"
    a, b, c, d, e = st.columns(5)
    a.metric("Last run status", f"{'‚úÖ' if ok else '‚ùå'} {lr.STATUS}")
    b.metric("Last run (ended)", str(lr.ENDED_AT or lr.STARTED_AT)[:19])
    c.metric("Data as-of", str(lr.DATA_AS_OF))
    d.metric("Code version", lr.CODE_VERSION)
    e.metric("Params", f"{lr.LOOKBACK}-{lr.SKIP} ¬∑ top {lr.N_HELD}")

    icon = {"SUCCEEDED": "‚úÖ", "FAILED": "‚ùå", "REUSED": "‚ôªÔ∏è"}
    st.markdown("**Stages in last run** (‚ôªÔ∏è = reused upstream table, rerun started at a later stage)")
    if stages.empty:
        st.info("No stage records for the last run.")
    else:
        s = stages.copy()
        s["STATUS"] = s["STATUS"].map(lambda x: f"{icon.get(x, '‚Ä¢')} {x}")
        s["ROW_COUNTS"] = s["ROW_COUNTS"].fillna("").astype(str).str.replace(r'[{}"]', "", regex=True)
        s["CODE_SHA256"] = s["CODE_SHA256"].fillna("").str[:12]
        st.dataframe(s, hide_index=True, use_container_width=True,
                     column_config={"ROW_COUNTS": "Rows per output table", "CODE_SHA256": "Code hash"})

    st.markdown("**Run history** (scheduled 1st of month 06:00 UTC + on-demand runs)")
    st.dataframe(history, hide_index=True, use_container_width=True)
*
ñÍÁ◊ f7ef262c469ec8bfb3ba9d08de9de5b1
Áb
	README.md≠b# ETF 12-1 Momentum Pipeline ‚Äî Snowflake PoC

A Snowflake implementation of the spec *"Snowflake PoC: ETF 12-1 Momentum Pipeline"* (Nov 12, 2026).
Everything (data, calculations, orchestration, run history, dashboard) lives in one account:
database **`ETF_MOMENTUM_POC`**, warehouse **`AICOLLEGE`**.

> **‚ö†Ô∏è Mock data.** This demo account has **no S&P Capital IQ XpressFeed share**, and the Snowflake
> Marketplace does not offer the CapIQ pricing tables (`CIQTRADINGITEM`, `CIQPRICEEQUITY`) as a
> self-serve listing ‚Äî they are licensed directly from S&P Global. Schema
> `ETF_MOMENTUM_POC.XPRESSFEED` is a **synthetic stand-in with the exact table and column names**
> from the spec, so the customer's CapIQ query runs unchanged. On the customer's account, set config
> key `source_schema` to `SPGLOBAL.XPRESSFEED`. No code changes are needed.

---

## 1. Layout

| File | What it is |
|---|---|
| `sql/00_setup.sql` | Database/schemas, `ETF_UNIVERSE` (49 tickers, 5 groups), **mock** CapIQ tables |
| `sql/01_universe.sql` | Stage 1 `SP_STAGE_UNIVERSE` ‚Üí `UNIVERSE` |
| `sql/02_ingest.sql` | Stage 2 `SP_STAGE_INGEST` ‚Üí `PRICES` (the customer's CapIQ query verbatim) |
| `sql/03_returns.sql` | Stage 3 `SP_STAGE_RETURNS` ‚Üí `DAILY_RETURNS`, `MONTHLY_RETURNS` (spec Step 1) |
| `sql/04_signal.sql` | Stage 4 `SP_STAGE_SIGNAL` ‚Üí `SIGNAL` (spec Step 2) |
| `sql/05_portfolios.sql` | Stage 5 `SP_STAGE_PORTFOLIOS` ‚Üí `HOLDINGS`, `PORTFOLIO_RETURNS` (spec Step 3) |
| `sql/06_performance.sql` | Stage 6 `SP_STAGE_PERFORMANCE` ‚Üí `PERF_SUMMARY`, `GROWTH` (spec Step 4) |
| `sql/07_orchestration.sql` | Run log tables, stage wrapper `SP_RUN_STAGE`, **task graph** |
| `sql/08_validation.sql` | The four acceptance checks |
| `dashboard/` | Streamlit in Snowflake app (4 panels, reads only pipeline tables + run log) |

Each stage file has a header block that documents what it reads, writes, the rules and its parameters.

### Task graph (declared in code: `07_orchestration.sql`)

```
T00_PIPELINE_START  (root ¬∑ CRON 0 6 1 * * UTC ¬∑ CONFIG = parameters ¬∑ TASK_AUTO_RETRY_ATTEMPTS = 1)
  ‚îî‚îÄ T01_UNIVERSE ‚Üí T02_INGEST ‚Üí T03_RETURNS ‚Üí T04_SIGNAL ‚Üí T05_PORTFOLIOS ‚Üí T06_PERFORMANCE
T99_PIPELINE_END    (finalizer: always runs, closes the run record with status + data as-of)
```

Every stage task calls `SP_RUN_STAGE(stage_no, run_id, config)`, which:

- skips stages before `start_stage` and logs them as `REUSED`, so a rerun from any stage reuses the upstream tables;
- runs `SP_STAGE_<NAME>`;
- logs start/end, status, `code_version`, a SHA-256 of the stage procedure code, the parameters, and the row count plus `HASH_AGG` content hash of each output table into `STAGE_RUNS`;
- snapshots each output table into `<TABLE>_HIST`, tagged with `RUN_ID`;
- on error, logs `FAILED` with the message and re-raises. Downstream tasks then don't run, and the graph retries once.

## 2. How to run

Deploy (or redeploy after a code change) straight from the workspace or Git files:

```sql
EXECUTE IMMEDIATE FROM 'snow://workspace/USER$.PUBLIC."etf-pipeline-momentum"/versions/live/sql/00_setup.sql';
-- ...repeat for 01..07 (07 creates and enables the task graph)
```

**Scheduled:** the root task runs automatically at 06:00 UTC on the 1st of every month (enabled; the next run is 2026-12-01).

**Full rerun on demand:**
```sql
EXECUTE TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START AWAIT;   -- AWAIT optional: waits and returns status
```

## 3. How to change a parameter (no code change)

Parameters are read from the task graph CONFIG at run time: `lookback_months` (12), `skip_months` (1),
`n_held` (16), `start_date` (2018-07-01), plus `start_stage` (1), `code_version` and `source_schema`.

One-off run with other values. Here it holds 10 ETFs and reruns from stage 5, reusing stages 1‚Äì4:
```sql
EXECUTE TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START USING CONFIG = $${
  "code_version":"v1.0.1","lookback_months":12,"skip_months":1,"n_held":10,
  "start_date":"2018-07-01","start_stage":5,"source_schema":"ETF_MOMENTUM_POC.XPRESSFEED"}$$ AWAIT;
```
`USING CONFIG` replaces the whole config for that run, so pass every key you care about. Missing keys fall back to the spec defaults.

To change the default used by the **monthly schedule**:
```sql
ALTER TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START SUSPEND;
ALTER TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START SET CONFIG = $${ ...same JSON... }$$;
ALTER TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START RESUME;
```

Rerun from stage *k*: same as above with `"start_stage": k` (1 = UNIVERSE ‚Ä¶ 6 = PERFORMANCE).

## 4. Logs and run history

| Where | What |
|---|---|
| `PIPELINE.PIPELINE_RUNS` | One row per run: status, start/end, code version, full params, data as-of, role |
| `PIPELINE.STAGE_RUNS` | One row per stage attempt: status (`SUCCEEDED` / `FAILED` / `REUSED`), timings, row counts and content hash per output table, code SHA-256, error message |
| `<TABLE>_HIST` (e.g. `SIGNAL_HIST`) | Every run's output, tagged with `RUN_ID`, so you can recover any earlier run's table |
| Snowsight ‚Üí Monitoring ‚Üí Task History / the task graph view on `T00_PIPELINE_START` | Native graph view: per-task state, retries (`ATTEMPT_NUMBER`), errors, query IDs |
| `TABLE(ETF_MOMENTUM_POC.INFORMATION_SCHEMA.TASK_HISTORY(...))` | Same in SQL (7 days); `SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY` keeps 365 days |

Recover an earlier run's table: `SELECT * FROM ETF_MOMENTUM_POC.PIPELINE.HOLDINGS_HIST WHERE RUN_ID = '<run_id>'`.
Time Travel (`AT(TIMESTAMP => ...)`) also works on the current tables for the retention period.

## 5. Dashboard

`dashboard/streamlit_app.py` is a Streamlit in Snowflake app on the container runtime (warehouse `AICOLLEGE`, pool `SYSTEM_COMPUTE_POOL_CPU`).
Open `dashboard/streamlit_app.py` in the workspace and click **Run**. It has four panels:

1. **Summary:** PERF_SUMMARY for MOMENTUM and BENCHMARK side by side.
2. **Growth of $1:** from GROWTH.
3. **Current holdings:** the latest MOMENTUM HOLDINGS joined to SIGNAL (12-1 momentum and rank).
4. **Pipeline status:** last run status and time, data as-of date, code version and parameters; per-stage status, duration and row counts; run history including failed and partial (rerun-from-stage) runs.

It reads only the pipeline tables and has no filters. Use **Refresh** after a run; the cache expires after 5 minutes anyway.

## 6. Validation status (run in this account, 2026-11-15)

| # | Spec check | Result |
|---|---|---|
| 1 | SPY monthly returns and one month's 16 holdings match the reference values | **‚ùå Cannot pass here.** The reference values come from real CapIQ prices and this demo uses mock prices. The comparison queries are ready in `08_validation.sql` (load the reference values into `REFERENCE_SPY` / `REFERENCE_HOLDINGS`). |
| 2 | A rerun on unchanged data reproduces every table exactly | **‚úÖ Pass.** All 9 output tables have identical row counts and `HASH_AGG` across two consecutive full runs. |
| 3 | Change one parameter (e.g. 10 ETFs) and rerun; every downstream table and the dashboard update, no code change | **‚úÖ Pass.** `n_held=10` with `start_stage=5`: stages 1‚Äì4 `REUSED`, HOLDINGS rebuilt with 10 names at weight 0.10, and PORTFOLIO_RETURNS, GROWTH and PERF_SUMMARY rebuilt. |
| 4 | The scheduled monthly run completes on its own; a broken input marks the failed stage and nothing downstream runs | **‚ö†Ô∏è Partly shown.** Failure path ‚úÖ: adding the bogus ticker `ZZZZ` made `T02_INGEST` FAIL with a readable error, it was retried once (attempt 2), and T03‚ÄìT06 did not run. The run shows as FAILED in `PIPELINE_RUNS` and the dashboard. Scheduled run ‚è≥: the CRON schedule is live, but its first fire is **2026-12-01 06:00 UTC**. Every run so far was on demand through the same root task. |

Spec dates reproduced: first signal **2019-07-31**, first portfolio month **August 2019**.

## 7. Where the spec is NOT (fully) met ‚Äî explicit list

1. **No real CapIQ data.** `SPGLOBAL.XPRESSFEED` isn't in this account, and CapIQ pricing isn't a self-serve Marketplace listing (S&P Capital IQ *Financials* is fundamentals, not prices). All numbers are synthetic, so check 1 can't pass here. The mock data deliberately includes ~0.2% missing days, 41 NULL or zero closes, and decoy `PRIMARYFLAG=0` listings, so the spec's gap, bad-close and primary-listing rules are exercised.
2. **"Data from 2018-07-01 to the latest available date."** The mock data ends on 2026-11-13. The open month (November 2026) is excluded from monthly returns because its last trading day hasn't happened yet. The month-end rule uses the last date with any price; exchange holidays aren't modelled separately.
3. **Customer's own Git repository.** The code is laid out as a repo (`sql/`, `dashboard/`, README), but it lives in this Snowsight workspace. Connecting the customer's GitHub needs their credentials: an API integration plus `CREATE GIT REPOSITORY`. After that, deploy with `EXECUTE IMMEDIATE FROM @repo/branches/main/sql/0X_*.sql`, and set `code_version` to the Git commit SHA.
4. **"Retried once" scope.** `TASK_AUTO_RETRY_ATTEMPTS = 1` retries the graph run from the failed task. It doesn't retry an isolated task while the rest carry on. That is the behaviour the spec describes, but the mechanism is graph-level.
5. **Code version tied to a run.** Each stage records the `code_version` label from the config and the SHA-256 of the exact procedure DDL it ran. A Git commit SHA needs item 3.
6. **"Input snapshot."** Stage 2 snapshots `PRICES` per run (`PRICES_HIST`). The upstream share itself can't be snapshotted. A zero-copy clone of a shared database isn't possible, so per-run `PRICES_HIST` is the input snapshot.
7. **Ties.** `RANK` uses SQL `RANK()` (ties share a rank). MOMENTUM selection breaks a tie at the cut-off by ticker so the 16 names are deterministic. The spec doesn't define tie handling.
8. **Benchmark with a data gap.** BENCHMARK holds all 49 at 1/49. If a holding has no `RET_M` in the holding month, the portfolio return averages the holdings that have one. The same applies to MOMENTUM.
9. **R.** Not built. Everything here is SQL. See the open questions below.
10. **Cost per stage.** Not measured for production scale. A full demo run takes about 40 seconds on `AICOLLEGE`. Measure per stage with the query in ¬ß8.
11. **30-minute walkthrough.** A person has to give this; it isn't something code can deliver.

## 8. Answers to the spec's open questions (short form)

- **Orchestration:** Snowflake **task graphs**, because they are native: CRON plus on-demand, CONFIG parameters, dependencies declared in code, auto-retry, a finalizer, graph-view history, and no extra infrastructure. dbt Projects on Snowflake would also fit and could be scheduled by the same tasks. An external orchestrator (Airflow) is only worth adding if Snowflake is one step in a wider workflow.
- **R:** run the existing R scripts as containers in **Snowpark Container Services** (job services from a task). They reach the data through the Snowflake ODBC/ADBC driver with the service's OAuth token, so nothing is exported. Not demonstrated here.
- **CapIQ share update time and completeness:** S&P Global publishes the update schedule and SLA for XpressFeed; we haven't confirmed it here. A completeness gate can be added to Stage 2 (for example, require all 49 tickers on the latest date, or check a load-control table if S&P provides one) before the stage succeeds.
- **Versioning outputs:** per-run snapshot tables (`<TABLE>_HIST`, tagged `RUN_ID`), plus content hashes in `STAGE_RUNS`, plus Time Travel. Zero-copy `CLONE` per run is an alternative for big tables, but it isn't built here.
- **Cost:**
  ```sql
  SELECT s.STAGE, SUM(q.CREDITS_ATTRIBUTED_COMPUTE) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY q
  JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h ON h.QUERY_ID = q.QUERY_ID
  JOIN ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS s
    ON h.START_TIME BETWEEN s.STARTED_AT AND s.ENDED_AT AND h.WAREHOUSE_NAME = 'AICOLLEGE'
  GROUP BY 1;   -- ACCOUNT_USAGE has up to ~3h latency
  ```
  At "a few thousand stocks, daily data, more signals" scale, measure this rather than estimate it.
- **Own Git repo:** yes (see ¬ß7 item 3).

## 9. Extending (researchers)

- **New signal:** copy `04_signal.sql` to a new stage procedure, add a task `AFTER T03_RETURNS`, and register its output tables in the `CASE` lists in `SP_RUN_STAGE`.
- **New universe:** edit `ETF_UNIVERSE` (it's a table, not code) and rerun. Stage 2 fails clearly if a ticker has no CapIQ prices.
*
⁄ÍÁ◊ b950b052efec0a448e5a105d3a9f5771
†
sql/10_scale_test.sqlÿ-- =====================================================================
-- 10_scale_test.sql : cost at the customer's target scale
-- "a few thousand stocks, daily data" -> 3,000 synthetic tickers ST0001..ST3000
-- added to the MOCK source and to ETF_UNIVERSE (group 'Scale test').
-- Run SETUP, run the pipeline (see README), then TEARDOWN to restore the demo.
-- =====================================================================

-- ------------------------------- SETUP --------------------------------
INSERT INTO ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM
SELECT 3000000 + n, 'ST' || LPAD(n::STRING, 4, '0'), 1
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 3000)));

INSERT INTO ETF_MOMENTUM_POC.XPRESSFEED.CIQPRICEEQUITY
WITH days AS (
  SELECT d FROM (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2018-06-01'::DATE) AS d
                 FROM TABLE(GENERATOR(ROWCOUNT => 3200)))
  WHERE d <= '2026-11-13' AND DAYOFWEEKISO(d) <= 5
),
ti AS (
  SELECT TRADINGITEMID, TICKERSYMBOL AS TICKER, 20 + MOD(ABS(HASH(TICKERSYMBOL)), 400) AS p0
  FROM ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM WHERE TICKERSYMBOL LIKE 'ST____'
),
raw AS (
  SELECT ti.TRADINGITEMID, ti.TICKER, ti.p0, k.d,
         0.0004
         + 0.0010 * ((MOD(ABS(HASH(ti.TICKER, YEAR(k.d), QUARTER(k.d))), 1000000) / 1e6) - 0.45)
         + 0.02 * SQRT(-2 * LN((MOD(ABS(HASH(ti.TICKER, k.d, 1)), 1000000) + 0.5) / 1e6))
                * COS(2 * PI() * (MOD(ABS(HASH(ti.TICKER, k.d, 2)), 1000000) + 0.5) / 1e6) AS lr
  FROM ti CROSS JOIN days k
)
SELECT TRADINGITEMID, d::TIMESTAMP_NTZ,
       ROUND(p0 * EXP(SUM(lr) OVER (PARTITION BY TRADINGITEMID ORDER BY d ROWS UNBOUNDED PRECEDING)), 4),
       100000 + MOD(ABS(HASH(TICKER, d, 'vol')), 5000000)
FROM raw;

INSERT INTO ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE
SELECT TICKERSYMBOL, 'Scale test' FROM ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM WHERE TICKERSYMBOL LIKE 'ST____';

-- ------------------------------ TEARDOWN ------------------------------
-- DELETE FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE WHERE GROUP_NAME = 'Scale test';
-- DELETE FROM ETF_MOMENTUM_POC.XPRESSFEED.CIQPRICEEQUITY WHERE TRADINGITEMID BETWEEN 3000001 AND 3003000;
-- DELETE FROM ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM WHERE TICKERSYMBOL LIKE 'ST____';
-- Then drop scale-test rows from the snapshot tables (keeps the run log rows):
--   DELETE FROM <each>_HIST WHERE RUN_ID IN (SELECT RUN_ID FROM ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS
--                                            WHERE PARAMS:test::STRING LIKE 'B-%');
-- and rerun the pipeline once with the default config.
,
˘ÚÁ◊""21175aac8ab2ed297ccceadd8a29e72e"
ú+
sql/09_cost_test.sql◊*-- =====================================================================
-- 09_cost_test.sql : what does a pipeline run cost?
-- ---------------------------------------------------------------------
-- The pipeline runs on its own warehouse ETF_POC_WH (07_orchestration.sql),
-- so ETF_POC_WH's metering = this pipeline's compute cost.
--
-- PRICES: on-demand LIST prices, no capacity / tier discount,
-- AWS US West 2 (this account). Confirm against your Order Form /
-- Snowflake's Service Consumption Table before quoting.
--   credit:  Standard $2.00 | Enterprise $3.00 | Business Critical $4.00
--   storage: $23 per TB-month
--   X-Small = 1 credit/hr, Small = 2, Medium = 4 (Gen1 standard warehouse)
--
-- Three views of cost, from most to least precise but available:
--   A. METERED  - WAREHOUSE_METERING_HISTORY (actual billed credits; ~3h lag)
--   B. RUN      - run wall time + 60s auto-suspend tail (what you are billed
--                 per run when nothing else uses the warehouse; no lag)
--   C. STAGE    - stage wall time from STAGE_RUNS (per-stage breakdown)
-- =====================================================================

CREATE OR REPLACE VIEW ETF_MOMENTUM_POC.PIPELINE.LIST_PRICES AS
SELECT * FROM VALUES
  ('STANDARD',          2.00::NUMBER(6,2), 23.00::NUMBER(6,2)),
  ('ENTERPRISE',        3.00, 23.00),
  ('BUSINESS_CRITICAL', 4.00, 23.00)
  AS t(EDITION, USD_PER_CREDIT, USD_PER_TB_MONTH);

-- C. Per-stage compute, per run (wall time x warehouse credit rate) ----------
CREATE OR REPLACE VIEW ETF_MOMENTUM_POC.PIPELINE.COST_BY_STAGE AS
SELECT s.RUN_ID, r.CODE_VERSION, r.STARTED_AT AS RUN_STARTED_AT,
       COALESCE(r.PARAMS:warehouse_credits_per_hour::FLOAT, 1) AS CREDITS_PER_HOUR,
       s.STAGE_NO, s.STAGE, s.STATUS,
       DATEDIFF('millisecond', s.STARTED_AT, s.ENDED_AT) / 1000 AS SECONDS,
       DATEDIFF('millisecond', s.STARTED_AT, s.ENDED_AT) / 3600000
         * COALESCE(r.PARAMS:warehouse_credits_per_hour::FLOAT, 1) AS CREDITS
FROM ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS s
JOIN ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS r ON r.RUN_ID = s.RUN_ID
WHERE s.STATUS = 'SUCCEEDED';

-- B. Per-run billed compute (wall time incl. task hand-offs + 60s suspend tail)
CREATE OR REPLACE VIEW ETF_MOMENTUM_POC.PIPELINE.COST_BY_RUN AS
SELECT r.RUN_ID, r.CODE_VERSION, r.STATUS, r.STARTED_AT,
       COALESCE(r.PARAMS:warehouse_credits_per_hour::FLOAT, 1) AS CREDITS_PER_HOUR,
       (SELECT COUNT(*) FROM ETF_MOMENTUM_POC.PIPELINE.UNIVERSE_HIST h WHERE h.RUN_ID = r.RUN_ID) AS N_TICKERS,
       DATEDIFF('millisecond', r.STARTED_AT, r.ENDED_AT) / 1000 AS RUN_SECONDS,
       (DATEDIFF('millisecond', r.STARTED_AT, r.ENDED_AT) / 1000 + 60) / 3600
         * COALESCE(r.PARAMS:warehouse_credits_per_hour::FLOAT, 1) AS BILLED_CREDITS
FROM ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS r
WHERE r.ENDED_AT IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Report 1: per-stage cost of the latest successful full run, in $ per edition
-- ---------------------------------------------------------------------------
WITH last_run AS (
  SELECT RUN_ID FROM ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS
  WHERE STATUS = 'SUCCEEDED' AND COALESCE(PARAMS:start_stage::INT, 1) = 1
  ORDER BY STARTED_AT DESC LIMIT 1
)
SELECT c.STAGE_NO, c.STAGE, ROUND(c.SECONDS, 1) AS SECONDS, ROUND(c.CREDITS, 5) AS CREDITS,
       ROUND(c.CREDITS * 2, 4) AS USD_STANDARD, ROUND(c.CREDITS * 3, 4) AS USD_ENTERPRISE,
       ROUND(c.CREDITS * 4, 4) AS USD_BUSINESS_CRITICAL
FROM ETF_MOMENTUM_POC.PIPELINE.COST_BY_STAGE c
WHERE c.RUN_ID = (SELECT RUN_ID FROM last_run)
ORDER BY c.STAGE_NO;

-- ---------------------------------------------------------------------------
-- Report 2: per-run billed cost, recent runs
-- ---------------------------------------------------------------------------
SELECT RUN_ID, CODE_VERSION, STATUS, N_TICKERS, CREDITS_PER_HOUR, RUN_SECONDS,
       ROUND(BILLED_CREDITS, 5) AS BILLED_CREDITS,
       ROUND(BILLED_CREDITS * 3, 4) AS USD_ENTERPRISE
FROM ETF_MOMENTUM_POC.PIPELINE.COST_BY_RUN
ORDER BY STARTED_AT DESC LIMIT 20;

-- ---------------------------------------------------------------------------
-- Report 3: ACTUAL metered credits on ETF_POC_WH (ground truth; ~3h latency)
-- ---------------------------------------------------------------------------
SELECT DATE_TRUNC('day', START_TIME) AS DAY,
       SUM(CREDITS_USED_COMPUTE)        AS COMPUTE_CREDITS,
       SUM(CREDITS_USED_CLOUD_SERVICES) AS CLOUD_SERVICES_CREDITS,  -- free up to 10% of daily compute
       ROUND(SUM(CREDITS_USED_COMPUTE) * 3, 2) AS USD_ENTERPRISE
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE WAREHOUSE_NAME = 'ETF_POC_WH'
GROUP BY 1 ORDER BY 1 DESC;

-- ---------------------------------------------------------------------------
-- Report 4: storage (incl. _HIST snapshots, Time Travel, Fail-safe)
-- ---------------------------------------------------------------------------
SELECT TABLE_SCHEMA,
       ROUND(SUM(ACTIVE_BYTES) / POWER(1024, 3), 3)       AS ACTIVE_GB,
       ROUND(SUM(TIME_TRAVEL_BYTES) / POWER(1024, 3), 3)  AS TIME_TRAVEL_GB,
       ROUND(SUM(FAILSAFE_BYTES) / POWER(1024, 3), 3)     AS FAILSAFE_GB,
       ROUND(SUM(ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES) / POWER(1024, 4) * 23, 4) AS USD_PER_MONTH
FROM ETF_MOMENTUM_POC.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG = 'ETF_MOMENTUM_POC' AND TABLE_DROPPED IS NULL
GROUP BY 1 ORDER BY 1;
*
◊Á◊ b71ed131ab5180932ff8f2e1fc25da16
¨R
sql/07_orchestration.sql„Q-- =====================================================================
-- 07_orchestration.sql : run log, stage wrapper, task graph
-- ---------------------------------------------------------------------
-- Task graph (declared in code, runs on schedule or on demand):
--
--   T00_PIPELINE_START (root, CRON 1st of month 06:00 UTC, CONFIG, retry 1)
--     -> T01_UNIVERSE -> T02_INGEST -> T03_RETURNS -> T04_SIGNAL
--     -> T05_PORTFOLIOS -> T06_PERFORMANCE
--   T99_PIPELINE_END (finalizer: always runs, closes the run record)
--
-- Every stage task calls SP_RUN_STAGE(stage_no, run_id, config), which:
--   * skips (status REUSED) stages before config.start_stage -> rerun from
--     any stage reuses the upstream tables as they are;
--   * calls the stage procedure SP_STAGE_<NAME>;
--   * records start/end, status, code_version, SHA-256 of the stage code,
--     parameters, row count + HASH_AGG fingerprint per output table;
--   * snapshots every output table into <TABLE>_HIST tagged with RUN_ID;
--   * on error logs FAILED + error message and re-raises, so the task fails,
--     downstream tasks do not run, and the root's auto-retry kicks in.
-- =====================================================================

-- Dedicated warehouse: its metering history = this pipeline's compute cost.
CREATE WAREHOUSE IF NOT EXISTS ETF_POC_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE COMMENT = 'Dedicated to ETF momentum pipeline (cost attribution)';

CREATE TABLE IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS (
  RUN_ID STRING, STATUS STRING, STARTED_AT TIMESTAMP_LTZ, ENDED_AT TIMESTAMP_LTZ,
  CODE_VERSION STRING, PARAMS VARIANT, DATA_AS_OF DATE, RUN_BY_ROLE STRING);

CREATE TABLE IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS (
  RUN_ID STRING, STAGE_NO INT, STAGE STRING, STATUS STRING,
  STARTED_AT TIMESTAMP_LTZ, ENDED_AT TIMESTAMP_LTZ,
  CODE_VERSION STRING, CODE_SHA256 STRING, PARAMS VARIANT,
  ROW_COUNTS VARIANT, TABLE_HASHES VARIANT, MESSAGE STRING, ERROR_MESSAGE STRING);

-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(STAGE_NO INT, RUN_ID STRING, CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  cfg VARIANT;
  stage STRING;
  tbls ARRAY;
  started TIMESTAMP_LTZ;
  code_ver STRING;
  code_sha STRING;
  msg STRING;
  q STRING;
  t STRING;
  c INT;
  h STRING;
  counts OBJECT DEFAULT OBJECT_CONSTRUCT();
  hashes OBJECT DEFAULT OBJECT_CONSTRUCT();
  start_stage INT;
  err STRING;
BEGIN
  started  := CURRENT_TIMESTAMP();
  cfg      := PARSE_JSON(COALESCE(NULLIF(CFG_STR, ''), '{}'));
  code_ver := COALESCE(cfg:code_version::STRING, 'unversioned');
  stage := CASE STAGE_NO WHEN 1 THEN 'UNIVERSE' WHEN 2 THEN 'INGEST' WHEN 3 THEN 'RETURNS'
                         WHEN 4 THEN 'SIGNAL'   WHEN 5 THEN 'PORTFOLIOS' WHEN 6 THEN 'PERFORMANCE' END;
  tbls  := CASE STAGE_NO WHEN 1 THEN ARRAY_CONSTRUCT('UNIVERSE')
                         WHEN 2 THEN ARRAY_CONSTRUCT('PRICES')
                         WHEN 3 THEN ARRAY_CONSTRUCT('DAILY_RETURNS', 'MONTHLY_RETURNS')
                         WHEN 4 THEN ARRAY_CONSTRUCT('SIGNAL')
                         WHEN 5 THEN ARRAY_CONSTRUCT('HOLDINGS', 'PORTFOLIO_RETURNS')
                         WHEN 6 THEN ARRAY_CONSTRUCT('PERF_SUMMARY', 'GROWTH') END;

  -- rerun-from-stage: reuse upstream tables untouched
  start_stage := COALESCE(cfg:start_stage::INT, 1);
  IF (STAGE_NO < start_stage) THEN
    INSERT INTO ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS
      (RUN_ID, STAGE_NO, STAGE, STATUS, STARTED_AT, ENDED_AT, CODE_VERSION, PARAMS, MESSAGE)
      SELECT :RUN_ID, :STAGE_NO, :stage, 'REUSED', :started, CURRENT_TIMESTAMP(), :code_ver, PARSE_JSON(:CFG_STR),
             'start_stage=' || :start_stage || ': upstream tables reused';
    RETURN 'REUSED';
  END IF;

  -- fingerprint of the exact stage code that runs
  q := 'SELECT SHA2(GET_DDL(''PROCEDURE'', ''ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_' || stage || '(VARCHAR)''), 256)';
  EXECUTE IMMEDIATE :q;
  SELECT $1 INTO :code_sha FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  -- run the stage
  q := 'CALL ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_' || stage || '(?)';
  EXECUTE IMMEDIATE :q USING (CFG_STR);
  SELECT $1 INTO :msg FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  -- row counts, content hashes, versioned snapshot per output table
  FOR i IN 0 TO ARRAY_SIZE(tbls) - 1 DO
    t := GET(tbls, i)::STRING;
    q := 'SELECT COUNT(*), HASH_AGG(*)::STRING FROM ETF_MOMENTUM_POC.PIPELINE.' || t;
    EXECUTE IMMEDIATE :q;
    SELECT $1, $2 INTO :c, :h FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    counts := OBJECT_INSERT(counts, t, c);
    hashes := OBJECT_INSERT(hashes, t, h);

    q := 'CREATE TABLE IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE.' || t || '_HIST AS ' ||
         'SELECT ''''::VARCHAR(200) AS RUN_ID, * FROM ETF_MOMENTUM_POC.PIPELINE.' || t || ' WHERE 1 = 0';
    EXECUTE IMMEDIATE :q;
    q := 'INSERT INTO ETF_MOMENTUM_POC.PIPELINE.' || t || '_HIST SELECT ?, * FROM ETF_MOMENTUM_POC.PIPELINE.' || t;
    EXECUTE IMMEDIATE :q USING (RUN_ID);
  END FOR;

  INSERT INTO ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS
    (RUN_ID, STAGE_NO, STAGE, STATUS, STARTED_AT, ENDED_AT, CODE_VERSION, CODE_SHA256, PARAMS, ROW_COUNTS, TABLE_HASHES, MESSAGE)
    SELECT :RUN_ID, :STAGE_NO, :stage, 'SUCCEEDED', :started, CURRENT_TIMESTAMP(), :code_ver, :code_sha,
           PARSE_JSON(:CFG_STR), :counts, :hashes, :msg;
  RETURN 'SUCCEEDED';

EXCEPTION
  WHEN OTHER THEN
    err := SQLERRM;
    INSERT INTO ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS
      (RUN_ID, STAGE_NO, STAGE, STATUS, STARTED_AT, ENDED_AT, CODE_VERSION, CODE_SHA256, PARAMS, ERROR_MESSAGE)
      SELECT :RUN_ID, :STAGE_NO, :stage, 'FAILED', :started, CURRENT_TIMESTAMP(), :code_ver, :code_sha,
             PARSE_JSON(:CFG_STR), :err;
    RAISE;
END;
$$;

-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_START_RUN(RUN_ID STRING, CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  MERGE INTO ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS t
  USING (SELECT :RUN_ID AS RUN_ID) s ON t.RUN_ID = s.RUN_ID
  WHEN MATCHED THEN UPDATE SET STATUS = 'RUNNING', ENDED_AT = NULL
  WHEN NOT MATCHED THEN INSERT (RUN_ID, STATUS, STARTED_AT, CODE_VERSION, PARAMS, RUN_BY_ROLE)
    VALUES (:RUN_ID, 'RUNNING', CURRENT_TIMESTAMP(),
            COALESCE(PARSE_JSON(:CFG_STR):code_version::STRING, 'unversioned'),
            PARSE_JSON(:CFG_STR), CURRENT_ROLE());
  RETURN 'STARTED ' || RUN_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_END_RUN(RUN_ID STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  final_status STRING;
BEGIN
  -- latest attempt per stage decides (a stage that failed then succeeded on retry counts as succeeded)
  SELECT CASE WHEN COUNT_IF(STATUS = 'FAILED') > 0 THEN 'FAILED'
              WHEN COUNT(*) < 6 THEN 'FAILED'
              ELSE 'SUCCEEDED' END INTO :final_status
  FROM (SELECT STAGE_NO, STATUS FROM ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS
        WHERE RUN_ID = :RUN_ID
        QUALIFY ROW_NUMBER() OVER (PARTITION BY STAGE_NO ORDER BY ENDED_AT DESC) = 1);

  UPDATE ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS
     SET STATUS = :final_status, ENDED_AT = CURRENT_TIMESTAMP(),
         DATA_AS_OF = (SELECT MAX(PRICE_DATE) FROM ETF_MOMENTUM_POC.PIPELINE.PRICES)
   WHERE RUN_ID = :RUN_ID;
  RETURN final_status;
END;
$$;

-- ---------------------------------------------------------------------
-- Task graph. Parameters live in the root task CONFIG (not in code).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START
  WAREHOUSE = ETF_POC_WH
  SCHEDULE = 'USING CRON 0 6 1 * * UTC'
  TASK_AUTO_RETRY_ATTEMPTS = 1
  CONFIG = $${"code_version": "v1.0.1", "lookback_months": 12, "skip_months": 1, "n_held": 16,
             "start_date": "2018-07-01", "start_stage": 1, "source_schema": "ETF_MOMENTUM_POC.XPRESSFEED"}$$
  COMMENT = 'ETF 12-1 momentum pipeline root: monthly on the 1st, or EXECUTE TASK ... USING CONFIG'
AS
  CALL ETF_MOMENTUM_POC.PIPELINE.SP_START_RUN(
    SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T01_UNIVERSE WAREHOUSE = ETF_POC_WH
  AFTER ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(1, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T02_INGEST WAREHOUSE = ETF_POC_WH
  AFTER ETF_MOMENTUM_POC.PIPELINE.T01_UNIVERSE
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(2, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T03_RETURNS WAREHOUSE = ETF_POC_WH
  AFTER ETF_MOMENTUM_POC.PIPELINE.T02_INGEST
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(3, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T04_SIGNAL WAREHOUSE = ETF_POC_WH
  AFTER ETF_MOMENTUM_POC.PIPELINE.T03_RETURNS
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(4, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T05_PORTFOLIOS WAREHOUSE = ETF_POC_WH
  AFTER ETF_MOMENTUM_POC.PIPELINE.T04_SIGNAL
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(5, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T06_PERFORMANCE WAREHOUSE = ETF_POC_WH
  AFTER ETF_MOMENTUM_POC.PIPELINE.T05_PORTFOLIOS
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_RUN_STAGE(6, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), SYSTEM$GET_TASK_GRAPH_CONFIG());

CREATE OR REPLACE TASK ETF_MOMENTUM_POC.PIPELINE.T99_PIPELINE_END WAREHOUSE = ETF_POC_WH
  FINALIZE = ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START
AS CALL ETF_MOMENTUM_POC.PIPELINE.SP_END_RUN(SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'));

-- Enable the graph (children + finalizer first, root last) -> monthly schedule is live.
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START');
*
˝ÔÁ◊ cf31f481282a530ee5f01a28d3162a7b
ƒ$
sql/08_validation.sql˛#-- =====================================================================
-- 08_validation.sql : the four acceptance checks from the PoC spec
-- Run each block in a worksheet. They read only pipeline tables + run log.
-- =====================================================================

-- ---------------------------------------------------------------------
-- CHECK 1 : SPY monthly returns and one month's 16 holdings vs reference.
-- Paste the customer's reference values into REFERENCE_SPY / REFERENCE_HOLDINGS.
-- !! With MOCK data this check cannot pass - reference numbers come from
-- !! real CapIQ prices. It is ready to run once source_schema = SPGLOBAL.XPRESSFEED.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE.REFERENCE_SPY (MONTH_END DATE, RET_M FLOAT);
CREATE TABLE IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE.REFERENCE_HOLDINGS (MONTH_END DATE, TICKER STRING);

SELECT COALESCE(r.MONTH_END, m.MONTH_END) AS MONTH_END, r.RET_M AS REF_RET_M, m.RET_M AS PIPELINE_RET_M,
       IFF(ABS(r.RET_M - m.RET_M) < 1e-8, 'MATCH', 'MISMATCH') AS RESULT
FROM ETF_MOMENTUM_POC.PIPELINE.REFERENCE_SPY r
LEFT JOIN ETF_MOMENTUM_POC.PIPELINE.MONTHLY_RETURNS m ON m.TICKER = 'SPY' AND m.MONTH_END = r.MONTH_END
ORDER BY 1;

SELECT COALESCE(r.TICKER, h.TICKER) AS TICKER,
       IFF(r.TICKER IS NOT NULL AND h.TICKER IS NOT NULL, 'MATCH', 'MISMATCH') AS RESULT
FROM ETF_MOMENTUM_POC.PIPELINE.REFERENCE_HOLDINGS r
FULL JOIN (SELECT MONTH_END, TICKER FROM ETF_MOMENTUM_POC.PIPELINE.HOLDINGS
           WHERE PORTFOLIO = 'MOMENTUM'
             AND MONTH_END IN (SELECT MONTH_END FROM ETF_MOMENTUM_POC.PIPELINE.REFERENCE_HOLDINGS)) h
  ON h.MONTH_END = r.MONTH_END AND h.TICKER = r.TICKER;

-- ---------------------------------------------------------------------
-- CHECK 2 : a rerun on unchanged data reproduces every table exactly.
-- Compares row count + HASH_AGG content hash of every output table between
-- the two most recent fully-run (start_stage = 1) successful runs.
-- ---------------------------------------------------------------------
WITH last2 AS (
  SELECT RUN_ID, ROW_NUMBER() OVER (ORDER BY STARTED_AT DESC) AS rn
  FROM ETF_MOMENTUM_POC.PIPELINE.PIPELINE_RUNS
  WHERE STATUS = 'SUCCEEDED' AND COALESCE(PARAMS:start_stage::INT, 1) = 1
  QUALIFY rn <= 2
)
SELECT a.STAGE, t.key AS TABLE_NAME,
       a.ROW_COUNTS[t.key]::INT AS ROWS_PREV, b.ROW_COUNTS[t.key]::INT AS ROWS_LATEST,
       t.value::STRING AS HASH_PREV, b.TABLE_HASHES[t.key]::STRING AS HASH_LATEST,
       IFF(t.value::STRING = b.TABLE_HASHES[t.key]::STRING, 'IDENTICAL', 'DIFFERENT') AS RESULT
FROM ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS a
JOIN ETF_MOMENTUM_POC.PIPELINE.STAGE_RUNS b ON b.STAGE_NO = a.STAGE_NO
, LATERAL FLATTEN(a.TABLE_HASHES) t
WHERE a.RUN_ID = (SELECT RUN_ID FROM last2 WHERE rn = 2)
  AND b.RUN_ID = (SELECT RUN_ID FROM last2 WHERE rn = 1)
ORDER BY a.STAGE_NO, TABLE_NAME;

-- ---------------------------------------------------------------------
-- CHECK 3 : change one parameter, rerun, no code change.
-- Example: hold 10 ETFs instead of 16, rerun from stage 5 (reuses 1-4).
-- ---------------------------------------------------------------------
-- EXECUTE TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START
--   USING CONFIG = $${"code_version":"v1.0.1","lookback_months":12,"skip_months":1,"n_held":10,
--                     "start_date":"2018-07-01","start_stage":5,"source_schema":"ETF_MOMENTUM_POC.XPRESSFEED"}$$ AWAIT;
SELECT MONTH_END, PORTFOLIO, COUNT(*) AS N_HOLDINGS, ROUND(MAX(WEIGHT), 6) AS WEIGHT
FROM ETF_MOMENTUM_POC.PIPELINE.HOLDINGS
WHERE MONTH_END = (SELECT MAX(MONTH_END) FROM ETF_MOMENTUM_POC.PIPELINE.HOLDINGS)
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- CHECK 4 : break an input -> failed stage marked, nothing downstream runs.
-- Break: add a ticker CapIQ does not have; INGEST (stage 2) must fail.
-- ---------------------------------------------------------------------
-- INSERT INTO ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE VALUES ('ZZZZ', 'Broken input test');
-- EXECUTE TASK ETF_MOMENTUM_POC.PIPELINE.T00_PIPELINE_START AWAIT;   -- raises an error
SELECT NAME, STATE, ATTEMPT_NUMBER, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(ETF_MOMENTUM_POC.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()), RESULT_LIMIT => 1000))
WHERE SCHEMA_NAME = 'PIPELINE'
ORDER BY SCHEDULED_TIME DESC, NAME;
-- Repair:
-- DELETE FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE WHERE TICKER = 'ZZZZ';
*
πÖÁ◊ 7fc4deff3f9b0523b12ca076394fef4c
˘
sql/04_signal.sql∑-- =====================================================================
-- Stage 4 : SIGNAL  (spec Step 2: 12-1 momentum)
-- Reads : PIPELINE.MONTHLY_RETURNS
-- Writes: PIPELINE.SIGNAL (TICKER, MONTH_END, MOM_12_1, RANK)
-- Rules :
--  * MOM_(i,m) = prod_{k=skip}^{lookback-1} (1 + R_(i,m-k)) - 1
--    default lookback=12, skip=1  ->  k = 1..11 (11 months, skip latest).
--  * ETF must have ALL (lookback - skip) monthly returns; else it is left
--    out that month (no partial signals).
--  * Point-in-time: signal at m uses only months <= m-skip, and is applied
--    to month m+1 returns only (done in Stage 5).
--  * RANK: 1 = highest momentum (RANK(), ties share a rank).
-- Params: lookback_months (12), skip_months (1)
-- =====================================================================
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_SIGNAL(CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  cfg VARIANT;
  lookback INT;
  skip INT;
  need INT;
BEGIN
  cfg      := PARSE_JSON(CFG_STR);
  lookback := COALESCE(cfg:lookback_months::INT, 12);
  skip     := COALESCE(cfg:skip_months::INT, 1);
  need     := lookback - skip;

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.SIGNAL AS
  WITH formation AS (      -- every completed month end is a formation date
    SELECT DISTINCT MONTH_END FROM ETF_MOMENTUM_POC.PIPELINE.MONTHLY_RETURNS
  ),
  mom AS (
    SELECT r.TICKER, f.MONTH_END,
           EXP(SUM(LN(1 + r.RET_M)::NUMBER(38,18))) - 1 AS MOM_12_1,  -- fixed-point sum: reproducible
           COUNT(*) AS n_months
    FROM formation f
    JOIN ETF_MOMENTUM_POC.PIPELINE.MONTHLY_RETURNS r
      ON r.MONTH_END BETWEEN LAST_DAY(ADD_MONTHS(f.MONTH_END, -(:lookback - 1)))
                         AND LAST_DAY(ADD_MONTHS(f.MONTH_END, -:skip))
    GROUP BY 1, 2
    HAVING COUNT(*) = :need
  )
  SELECT TICKER, MONTH_END, MOM_12_1,
         RANK() OVER (PARTITION BY MONTH_END ORDER BY MOM_12_1 DESC) AS RANK
  FROM mom
  ORDER BY MONTH_END, RANK, TICKER;

  RETURN 'SIGNAL built (lookback=' || lookback || ', skip=' || skip || ')';
END;
$$;
*
ÜÉÁ◊ de459e033a8e3c1cdf4dec9743521961
ã
sql/03_returns.sql»-- =====================================================================
-- Stage 3 : RETURNS  (spec Step 1)
-- Reads : PIPELINE.PRICES
-- Writes: PIPELINE.DAILY_RETURNS   (TICKER, PRICE_DATE, CLOSE_ADJ, RET_D)
--         PIPELINE.MONTHLY_RETURNS (TICKER, MONTH_END, RET_M)
-- Rules :
--  * r_d = P_d / P_(d-1) - 1, where d-1 is the ETF's previous day WITH a
--    price (so the first day after a gap uses the last available close).
--  * R_m = prod(1 + r_d) - 1 over every trading day in calendar month m.
--  * R_m kept only if the ETF has a price on the month's last trading day
--    AND on the previous month's last trading day; otherwise the row is
--    absent (missing, never 0). "Last trading day" = last date with any
--    price in PRICES for that month.
--  * A month is labelled by its calendar last day (e.g. 2024-03-31).
--  * The current, still-open month is excluded (its last trading day has
--    not happened yet).
-- Params: none
-- =====================================================================
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_RETURNS(CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.DAILY_RETURNS AS
  SELECT TICKER, PRICE_DATE, PRICECLOSE AS CLOSE_ADJ,
         PRICECLOSE / LAG(PRICECLOSE) OVER (PARTITION BY TICKER ORDER BY PRICE_DATE) - 1 AS RET_D
  FROM ETF_MOMENTUM_POC.PIPELINE.PRICES
  ORDER BY TICKER, PRICE_DATE;

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.MONTHLY_RETURNS AS
  WITH max_d AS (
    SELECT MAX(PRICE_DATE) AS d FROM ETF_MOMENTUM_POC.PIPELINE.PRICES
  ),
  cal AS (   -- market calendar: last trading day of each month and of the month before
    SELECT LAST_DAY(PRICE_DATE) AS MONTH_END, MAX(PRICE_DATE) AS LAST_TD
    FROM ETF_MOMENTUM_POC.PIPELINE.PRICES
    GROUP BY 1
  ),
  cal2 AS (
    SELECT c.MONTH_END, c.LAST_TD,
           LAG(c.LAST_TD) OVER (ORDER BY c.MONTH_END) AS PREV_LAST_TD
    FROM cal c, max_d
    -- drop the open month: keep it only if data reaches its last weekday
    WHERE c.MONTH_END < LAST_DAY(max_d.d)
       OR max_d.d >= c.MONTH_END - CASE DAYOFWEEKISO(c.MONTH_END) WHEN 6 THEN 1 WHEN 7 THEN 2 ELSE 0 END
  ),
  comp AS (
    SELECT TICKER, LAST_DAY(PRICE_DATE) AS MONTH_END,
           EXP(SUM(LN(1 + RET_D)::NUMBER(38,18))) - 1 AS RET_M  -- fixed-point sum: order-independent, bit-reproducible
    FROM ETF_MOMENTUM_POC.PIPELINE.DAILY_RETURNS
    WHERE RET_D IS NOT NULL
    GROUP BY 1, 2
  )
  SELECT m.TICKER, m.MONTH_END, m.RET_M
  FROM comp m
  JOIN cal2 c ON c.MONTH_END = m.MONTH_END
  JOIN ETF_MOMENTUM_POC.PIPELINE.PRICES p1 ON p1.TICKER = m.TICKER AND p1.PRICE_DATE = c.LAST_TD
  JOIN ETF_MOMENTUM_POC.PIPELINE.PRICES p0 ON p0.TICKER = m.TICKER AND p0.PRICE_DATE = c.PREV_LAST_TD
  ORDER BY m.TICKER, m.MONTH_END;

  RETURN 'DAILY_RETURNS, MONTHLY_RETURNS built';
END;
$$;
*
·ÇÁ◊ b975647fe35a287588e7bd51cca454e4
£
sql/05_portfolios.sql›-- =====================================================================
-- Stage 5 : PORTFOLIOS  (spec Step 3)
-- Reads : PIPELINE.SIGNAL, PIPELINE.UNIVERSE, PIPELINE.MONTHLY_RETURNS
-- Writes: PIPELINE.HOLDINGS          (MONTH_END, PORTFOLIO, TICKER, WEIGHT)
--             MONTH_END = formation month end m (weights set at m)
--         PIPELINE.PORTFOLIO_RETURNS (MONTH_END, PORTFOLIO, RET)
--             MONTH_END = HOLDING month m+1
-- Rules :
--  * MOMENTUM : top n_held by MOM_12_1, weight 1/n_held. Ties at the cut-off
--               broken by ticker (alphabetical) so runs are deterministic.
--  * BENCHMARK: every UNIVERSE ticker, weight 1/N (N = 49 by default),
--               on the same formation dates as MOMENTUM.
--  * RET(m+1) = average RET_M of the holdings in month m+1 (equal weight,
--    long-only, no costs, no intra-month rebalancing). A holding with no
--    RET_M in m+1 (data gap) is excluded from that month's average.
--  * The latest formation date is kept in HOLDINGS (= "current holdings")
--    even though its holding month has not completed yet.
-- Params: n_held (16)
-- =====================================================================
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_PORTFOLIOS(CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  cfg VARIANT;
  n_held INT;
BEGIN
  cfg    := PARSE_JSON(CFG_STR);
  n_held := COALESCE(cfg:n_held::INT, 16);

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.HOLDINGS AS
  WITH dates AS (SELECT DISTINCT MONTH_END FROM ETF_MOMENTUM_POC.PIPELINE.SIGNAL),
  mom AS (
    SELECT MONTH_END, 'MOMENTUM' AS PORTFOLIO, TICKER
    FROM ETF_MOMENTUM_POC.PIPELINE.SIGNAL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MONTH_END ORDER BY MOM_12_1 DESC, TICKER) <= :n_held
  ),
  bench AS (
    SELECT d.MONTH_END, 'BENCHMARK' AS PORTFOLIO, u.TICKER
    FROM dates d CROSS JOIN ETF_MOMENTUM_POC.PIPELINE.UNIVERSE u
  ),
  h AS (SELECT * FROM mom UNION ALL SELECT * FROM bench)
  SELECT MONTH_END, PORTFOLIO, TICKER,
         1::FLOAT / COUNT(*) OVER (PARTITION BY MONTH_END, PORTFOLIO) AS WEIGHT
  FROM h
  ORDER BY MONTH_END, PORTFOLIO, TICKER;

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.PORTFOLIO_RETURNS AS
  SELECT r.MONTH_END, h.PORTFOLIO, AVG(r.RET_M::NUMBER(38,18))::FLOAT AS RET  -- fixed-point average: reproducible
  FROM ETF_MOMENTUM_POC.PIPELINE.HOLDINGS h
  JOIN ETF_MOMENTUM_POC.PIPELINE.MONTHLY_RETURNS r
    ON r.TICKER = h.TICKER
   AND r.MONTH_END = LAST_DAY(ADD_MONTHS(h.MONTH_END, 1))
  GROUP BY 1, 2
  ORDER BY 1, 2;

  RETURN 'HOLDINGS, PORTFOLIO_RETURNS built (n_held=' || n_held || ')';
END;
$$;
*
·ÇÁ◊ ebb2778d44f2777ec6b44bbd40f27c00
Ò
sql/06_performance.sql™-- =====================================================================
-- Stage 6 : PERFORMANCE  (spec Step 4)
-- Reads : PIPELINE.PORTFOLIO_RETURNS
-- Writes: PIPELINE.GROWTH       (MONTH_END, PORTFOLIO, VALUE, DRAWDOWN)
--         PIPELINE.PERF_SUMMARY (PORTFOLIO, TOTAL_RETURN, ANN_RETURN, ANN_VOL, MAX_DRAWDOWN)
-- Definitions (monthly returns R over n months):
--   TOTAL_RETURN = prod(1+R) - 1
--   ANN_RETURN   = prod(1+R)^(12/n) - 1
--   ANN_VOL      = sd(R) * sqrt(12)      (sample sd, as R's sd())
--   MAX_DRAWDOWN = largest fall of growth-of-$1 from its running peak
--                  (peak includes the $1 starting value; reported <= 0)
-- Params: none
-- =====================================================================
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_PERFORMANCE(CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.GROWTH AS
  WITH g AS (
    SELECT MONTH_END, PORTFOLIO,
           EXP(SUM(LN(1 + RET)) OVER (PARTITION BY PORTFOLIO ORDER BY MONTH_END
                                     ROWS UNBOUNDED PRECEDING)) AS VALUE
    FROM ETF_MOMENTUM_POC.PIPELINE.PORTFOLIO_RETURNS
  )
  SELECT MONTH_END, PORTFOLIO, VALUE,
         VALUE / GREATEST(1, MAX(VALUE) OVER (PARTITION BY PORTFOLIO ORDER BY MONTH_END
                                              ROWS UNBOUNDED PRECEDING)) - 1 AS DRAWDOWN
  FROM g
  ORDER BY PORTFOLIO, MONTH_END;

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.PERF_SUMMARY AS
  SELECT r.PORTFOLIO,
         -- sums in fixed-point NUMBER so results are bit-identical across reruns
         EXP(SUM(LN(1 + r.RET)::NUMBER(38,18))) - 1                              AS TOTAL_RETURN,
         POWER(EXP(SUM(LN(1 + r.RET)::NUMBER(38,18))), 12 / COUNT(*)::FLOAT) - 1 AS ANN_RETURN,
         SQRT((SUM(SQUARE(r.RET::NUMBER(38,18))::NUMBER(38,18))
               - SQUARE(SUM(r.RET::NUMBER(38,18))) / COUNT(*)) / (COUNT(*) - 1)) * SQRT(12) AS ANN_VOL,  -- = sd(R)*sqrt(12)
         MIN(g.DRAWDOWN)                                          AS MAX_DRAWDOWN,
         COUNT(*)                                                 AS N_MONTHS,
         MIN(r.MONTH_END)                                         AS FIRST_MONTH,
         MAX(r.MONTH_END)                                         AS LAST_MONTH
  FROM ETF_MOMENTUM_POC.PIPELINE.PORTFOLIO_RETURNS r
  JOIN ETF_MOMENTUM_POC.PIPELINE.GROWTH g
    ON g.PORTFOLIO = r.PORTFOLIO AND g.MONTH_END = r.MONTH_END
  GROUP BY r.PORTFOLIO
  ORDER BY r.PORTFOLIO;

  RETURN 'GROWTH, PERF_SUMMARY built';
END;
$$;
*
·ÇÁ◊ 4762302d209565a9abf334126315607e
¬+
sql/00_setup.sqlÅ+-- =====================================================================
-- 00_setup.sql : database, schemas, universe and MOCK CapIQ XpressFeed
-- ---------------------------------------------------------------------
-- MOCK DATA NOTICE: this account has no S&P XpressFeed share, so the
-- XPRESSFEED schema below is a synthetic stand-in with the SAME table and
-- column names the spec uses (CIQTRADINGITEM, CIQPRICEEQUITY). Prices are
-- deterministic synthetic random walks, NOT real market data.
-- To go live: point the PRICES ingest at SPGLOBAL.XPRESSFEED (pipeline
-- config key "source_db"), nothing else changes.
-- =====================================================================
CREATE DATABASE IF NOT EXISTS ETF_MOMENTUM_POC;
CREATE SCHEMA IF NOT EXISTS ETF_MOMENTUM_POC.XPRESSFEED COMMENT = 'MOCK of SPGLOBAL.XPRESSFEED (synthetic prices)';
CREATE SCHEMA IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE   COMMENT = 'ETF 12-1 momentum pipeline: stage outputs, run log, tasks';

-- ---------------- Universe (customer-provided table) -----------------
CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE (TICKER STRING NOT NULL, GROUP_NAME STRING NOT NULL);
INSERT INTO ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE
SELECT t.value::STRING, g.grp
FROM (SELECT 'Broad equity indices' grp, ARRAY_CONSTRUCT('SPY','IWM','EFA','EEM','QQQ','MDY') tk UNION ALL
      SELECT 'Sector SPDRs', ARRAY_CONSTRUCT('XLK','XLF','XLI','XLE','XLU','XLB','XLY','XLP','XLV','XLC') UNION ALL
      SELECT 'Industry and thematic', ARRAY_CONSTRUCT('KBE','KRE','XRT','SOXX','XBI','IBB','IHI','XHB','ITB','XOP','OIH','XME','GDX','VNQ','IYR','IYT','IGV','CIBR','ITA','IYZ','KIE','JETS') UNION ALL
      SELECT 'Commodities', ARRAY_CONSTRUCT('GLD','SLV','USO','DBA','DBB','DBC') UNION ALL
      SELECT 'Currencies', ARRAY_CONSTRUCT('FXE','FXY','FXA','FXB','UUP')) g,
     LATERAL FLATTEN(g.tk) t;

-- ---------------- Mock CIQTRADINGITEM --------------------------------
-- One primary (PRIMARYFLAG=1) trading item per ticker, plus a decoy
-- non-primary listing to prove the PRIMARYFLAG filter matters.
CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM AS
SELECT 1000000 + ROW_NUMBER() OVER (ORDER BY TICKER) AS TRADINGITEMID, TICKER AS TICKERSYMBOL, 1 AS PRIMARYFLAG
FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE
UNION ALL
SELECT 2000000 + ROW_NUMBER() OVER (ORDER BY TICKER), TICKER, 0
FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE;

-- ---------------- Mock CIQPRICEEQUITY --------------------------------
-- Weekday calendar 2018-06-01 .. 2026-11-13. Daily log return =
--   beta*market factor + ticker/year drift + idiosyncratic noise,
-- all from HASH-based Box-Muller draws so the data is fully deterministic.
-- ~0.2% of ticker-days are dropped (data gaps) and a few rows carry NULL/0
-- closes, to exercise the spec's gap and "drop non-positive close" rules.
CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.XPRESSFEED.CIQPRICEEQUITY AS
WITH days AS (
  SELECT d FROM (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2018-06-01'::DATE) AS d
                 FROM TABLE(GENERATOR(ROWCOUNT => 3200)))
  WHERE d <= '2026-11-13' AND DAYOFWEEKISO(d) <= 5
),
params AS (
  SELECT u.TICKER, u.GROUP_NAME, ti.TRADINGITEMID,
         CASE u.GROUP_NAME WHEN 'Broad equity indices' THEN 1.0 WHEN 'Sector SPDRs' THEN 0.95
              WHEN 'Industry and thematic' THEN 1.2 WHEN 'Commodities' THEN 0.3 ELSE 0.05 END AS beta,
         CASE u.GROUP_NAME WHEN 'Broad equity indices' THEN 0.006 WHEN 'Sector SPDRs' THEN 0.009
              WHEN 'Industry and thematic' THEN 0.014 WHEN 'Commodities' THEN 0.014 ELSE 0.004 END AS idio_vol,
         20 + MOD(ABS(HASH(u.TICKER)), 400) AS p0
  FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE u
  JOIN ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM ti ON ti.TICKERSYMBOL = u.TICKER AND ti.PRIMARYFLAG = 1
),
mkt AS (
  SELECT d, 0.0005 + 0.0011 * SQRT(-2*LN((MOD(ABS(HASH('MKT',d,1)),1000000)+0.5)/1e6)) * COS(2*PI()*(MOD(ABS(HASH('MKT',d,2)),1000000)+0.5)/1e6) * 10 AS f
  FROM days
),
raw AS (
  SELECT p.TRADINGITEMID, p.TICKER, k.d,
         p.p0,
         p.beta * m.f
         + 0.0008 * ((MOD(ABS(HASH(p.TICKER, YEAR(k.d), QUARTER(k.d))),1000000)/1e6) - 0.45)
         + p.idio_vol * SQRT(-2*LN((MOD(ABS(HASH(p.TICKER,k.d,1)),1000000)+0.5)/1e6)) * COS(2*PI()*(MOD(ABS(HASH(p.TICKER,k.d,2)),1000000)+0.5)/1e6) AS lr
  FROM params p CROSS JOIN days k JOIN mkt m ON m.d = k.d
),
px AS (
  SELECT TRADINGITEMID, TICKER, d,
         ROUND(p0 * EXP(SUM(lr) OVER (PARTITION BY TRADINGITEMID ORDER BY d ROWS UNBOUNDED PRECEDING)), 4) AS close_px,
         MOD(ABS(HASH(TICKER, d, 'gap')), 1000) AS gap_draw,
         MOD(ABS(HASH(TICKER, d, 'bad')), 5000) AS bad_draw
  FROM raw
)
SELECT TRADINGITEMID,
       d::TIMESTAMP_NTZ AS PRICINGDATE,
       CASE WHEN bad_draw = 0 THEN NULL WHEN bad_draw = 1 THEN 0 ELSE close_px END AS PRICECLOSE,
       100000 + MOD(ABS(HASH(TICKER, d, 'vol')), 5000000) AS VOLUME
FROM px
WHERE gap_draw >= 2                       -- ~0.2% gaps
UNION ALL                                 -- decoy non-primary listings (must be ignored)
SELECT ti.TRADINGITEMID, p.PRICINGDATE, p.PRICECLOSE * 1.37, p.VOLUME
FROM ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM ti
JOIN ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM tp ON tp.TICKERSYMBOL = ti.TICKERSYMBOL AND tp.PRIMARYFLAG = 1
JOIN (SELECT TRADINGITEMID, d::TIMESTAMP_NTZ AS PRICINGDATE, close_px AS PRICECLOSE, 1000 AS VOLUME FROM px) p
  ON p.TRADINGITEMID = tp.TRADINGITEMID
WHERE ti.PRIMARYFLAG = 0;
*
›˛Ê◊ 02e062b8f8cdb5b409aaf516f9d79ad5
£
sql/02_ingest.sql·-- =====================================================================
-- Stage 2 : INGEST
-- Reads : PIPELINE.UNIVERSE, <source_schema>.CIQTRADINGITEM, <source_schema>.CIQPRICEEQUITY
-- Writes: PIPELINE.PRICES (TICKER, PRICE_DATE, PRICECLOSE, VOLUME)
-- Logic : the customer's CapIQ query verbatim; rows with NULL / non-positive
--         PRICECLOSE dropped. PRICECLOSE is already split-adjusted.
-- Checks: every universe ticker must have prices, else the stage FAILS
--         (this is how "break an input" stops the pipeline).
-- Params: start_date   (default 2018-07-01)
--         source_schema (default ETF_MOMENTUM_POC.XPRESSFEED = MOCK;
--                        set to SPGLOBAL.XPRESSFEED for the real share)
-- =====================================================================
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_INGEST(CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  cfg VARIANT;
  start_date DATE;
  src STRING;
  ti_tbl STRING;
  px_tbl STRING;
  missing STRING;
  missing_tickers EXCEPTION (-20002, 'INGEST failed: one or more UNIVERSE tickers have no prices in the CapIQ source');
BEGIN
  cfg        := PARSE_JSON(CFG_STR);
  start_date := COALESCE(cfg:start_date::DATE, '2018-07-01'::DATE);
  src        := COALESCE(cfg:source_schema::STRING, 'ETF_MOMENTUM_POC.XPRESSFEED');
  ti_tbl     := src || '.CIQTRADINGITEM';
  px_tbl     := src || '.CIQPRICEEQUITY';

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.PRICES AS
  SELECT u.TICKER, p.PRICINGDATE::DATE AS PRICE_DATE,
         p.PRICECLOSE, p.VOLUME
  FROM ETF_MOMENTUM_POC.PIPELINE.UNIVERSE u
  JOIN IDENTIFIER(:ti_tbl) ti
    ON ti.TICKERSYMBOL = u.TICKER AND ti.PRIMARYFLAG = 1
  JOIN IDENTIFIER(:px_tbl) p
    ON p.TRADINGITEMID = ti.TRADINGITEMID
  WHERE p.PRICINGDATE >= :start_date
    AND p.PRICECLOSE IS NOT NULL AND p.PRICECLOSE > 0
  ORDER BY u.TICKER, PRICE_DATE;

  SELECT LISTAGG(u.TICKER, ',') WITHIN GROUP (ORDER BY u.TICKER) INTO :missing
  FROM ETF_MOMENTUM_POC.PIPELINE.UNIVERSE u
  WHERE NOT EXISTS (SELECT 1 FROM ETF_MOMENTUM_POC.PIPELINE.PRICES p WHERE p.TICKER = u.TICKER);
  IF (missing IS NOT NULL AND missing <> '') THEN
    RAISE missing_tickers;
  END IF;

  RETURN 'PRICES loaded from ' || src;
END;
$$;
*
Ω¸Ê◊ a41e27bdd22d70e8ba2a3ac6813b8b36
å	
sql/01_universe.sql»-- =====================================================================
-- Stage 1 : UNIVERSE
-- Reads : PIPELINE.ETF_UNIVERSE (customer-maintained: TICKER, GROUP_NAME)
-- Writes: PIPELINE.UNIVERSE      (frozen copy used by this run)
-- Checks: non-empty, no duplicate tickers. Fails the stage otherwise.
-- Params: none
-- =====================================================================
CREATE OR REPLACE PROCEDURE ETF_MOMENTUM_POC.PIPELINE.SP_STAGE_UNIVERSE(CFG_STR STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  n_rows INT;
  n_dupes INT;
  bad_universe EXCEPTION (-20001, 'ETF_UNIVERSE is empty or has duplicate tickers');
BEGIN
  SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT TICKER) INTO :n_rows, :n_dupes
  FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE;
  IF (n_rows = 0 OR n_dupes > 0) THEN
    RAISE bad_universe;
  END IF;

  CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.UNIVERSE AS
  SELECT UPPER(TRIM(TICKER)) AS TICKER, GROUP_NAME
  FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE
  ORDER BY TICKER;

  RETURN 'UNIVERSE: ' || n_rows || ' tickers';
END;
$$;
*
ú¸Ê◊ 99a701e3754add2329d6f0addba835b8
ì
dashboard/snowflake.ymlÀ# created-by: streamlit-in-workspaces; skill-version=1.0.0
definition_version: 2
entities:
  streamlit_app:
    type: streamlit
    query_warehouse: "AICOLLEGE"
    compute_pool: "SYSTEM_COMPUTE_POOL_CPU"
    main_file: streamlit_app.py
    artifacts:
      - pyproject.toml
      - streamlit_app.py
      - .streamlit/config.toml
*
˙ÈÁ◊ a771c685ecfa8d0c59b9cb303bf53dc4