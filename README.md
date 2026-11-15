# ETF 12-1 Momentum Pipeline — Snowflake PoC

A Snowflake implementation of the spec *"Snowflake PoC: ETF 12-1 Momentum Pipeline"* (Nov 12, 2026).
Everything (data, calculations, orchestration, run history, dashboard) lives in one account:
database **`ETF_MOMENTUM_POC`**, pipeline warehouse **`ETF_POC_WH`** (dedicated, X-Small), dashboard warehouse `AICOLLEGE`.

> **⚠️ Mock data.** This demo account has **no S&P Capital IQ XpressFeed share**, and the Snowflake
> Marketplace does not offer the CapIQ pricing tables (`CIQTRADINGITEM`, `CIQPRICEEQUITY`) as a
> self-serve listing — they are licensed directly from S&P Global. Schema
> `ETF_MOMENTUM_POC.XPRESSFEED` is a **synthetic stand-in with the exact table and column names**
> from the spec, so the customer's CapIQ query runs unchanged. On the customer's account, set config
> key `source_schema` to `SPGLOBAL.XPRESSFEED`. No code changes are needed.

---

## 1. Layout

| File | What it is |
|---|---|
| `sql/00_setup.sql` | Database/schemas, `ETF_UNIVERSE` (49 tickers, 5 groups), **mock** CapIQ tables |
| `sql/01_universe.sql` | Stage 1 `SP_STAGE_UNIVERSE` → `UNIVERSE` |
| `sql/02_ingest.sql` | Stage 2 `SP_STAGE_INGEST` → `PRICES` (the customer's CapIQ query verbatim) |
| `sql/03_returns.sql` | Stage 3 `SP_STAGE_RETURNS` → `DAILY_RETURNS`, `MONTHLY_RETURNS` (spec Step 1) |
| `sql/04_signal.sql` | Stage 4 `SP_STAGE_SIGNAL` → `SIGNAL` (spec Step 2) |
| `sql/05_portfolios.sql` | Stage 5 `SP_STAGE_PORTFOLIOS` → `HOLDINGS`, `PORTFOLIO_RETURNS` (spec Step 3) |
| `sql/06_performance.sql` | Stage 6 `SP_STAGE_PERFORMANCE` → `PERF_SUMMARY`, `GROWTH` (spec Step 4) |
| `sql/07_orchestration.sql` | Run log tables, stage wrapper `SP_RUN_STAGE`, **task graph** |
| `sql/08_validation.sql` | The four acceptance checks |
| `dashboard/` | Streamlit in Snowflake app (4 panels, reads only pipeline tables + run log) |

Each stage file has a header block that documents what it reads, writes, the rules and its parameters.

### Task graph (declared in code: `07_orchestration.sql`)

```
T00_PIPELINE_START  (root · CRON 0 6 1 * * UTC · CONFIG = parameters · TASK_AUTO_RETRY_ATTEMPTS = 1)
  └─ T01_UNIVERSE → T02_INGEST → T03_RETURNS → T04_SIGNAL → T05_PORTFOLIOS → T06_PERFORMANCE
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

One-off run with other values. Here it holds 10 ETFs and reruns from stage 5, reusing stages 1–4:
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

Rerun from stage *k*: same as above with `"start_stage": k` (1 = UNIVERSE … 6 = PERFORMANCE).

## 4. Logs and run history

| Where | What |
|---|---|
| `PIPELINE.PIPELINE_RUNS` | One row per run: status, start/end, code version, full params, data as-of, role |
| `PIPELINE.STAGE_RUNS` | One row per stage attempt: status (`SUCCEEDED` / `FAILED` / `REUSED`), timings, row counts and content hash per output table, code SHA-256, error message |
| `<TABLE>_HIST` (e.g. `SIGNAL_HIST`) | Every run's output, tagged with `RUN_ID`, so you can recover any earlier run's table |
| Snowsight → Monitoring → Task History / the task graph view on `T00_PIPELINE_START` | Native graph view: per-task state, retries (`ATTEMPT_NUMBER`), errors, query IDs |
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
| 1 | SPY monthly returns and one month's 16 holdings match the reference values | **❌ Cannot pass here.** The reference values come from real CapIQ prices and this demo uses mock prices. The comparison queries are ready in `08_validation.sql` (load the reference values into `REFERENCE_SPY` / `REFERENCE_HOLDINGS`). |
| 2 | A rerun on unchanged data reproduces every table exactly | **✅ Pass.** All 9 output tables have identical row counts and `HASH_AGG` across two consecutive full runs. |
| 3 | Change one parameter (e.g. 10 ETFs) and rerun; every downstream table and the dashboard update, no code change | **✅ Pass.** `n_held=10` with `start_stage=5`: stages 1–4 `REUSED`, HOLDINGS rebuilt with 10 names at weight 0.10, and PORTFOLIO_RETURNS, GROWTH and PERF_SUMMARY rebuilt. |
| 4 | The scheduled monthly run completes on its own; a broken input marks the failed stage and nothing downstream runs | **⚠️ Partly shown.** Failure path ✅: adding the bogus ticker `ZZZZ` made `T02_INGEST` FAIL with a readable error, it was retried once (attempt 2), and T03–T06 did not run. The run shows as FAILED in `PIPELINE_RUNS` and the dashboard. Scheduled run ⏳: the CRON schedule is live, but its first fire is **2026-12-01 06:00 UTC**. Every run so far was on demand through the same root task. |

Spec dates reproduced: first signal **2019-07-31**, first portfolio month **August 2019**.

## 7. Where the spec is NOT (fully) met — explicit list

1. **No real CapIQ data.** `SPGLOBAL.XPRESSFEED` isn't in this account, and CapIQ pricing isn't a self-serve Marketplace listing (S&P Capital IQ *Financials* is fundamentals, not prices). All numbers are synthetic, so check 1 can't pass here. The mock data deliberately includes ~0.2% missing days, 41 NULL or zero closes, and decoy `PRIMARYFLAG=0` listings, so the spec's gap, bad-close and primary-listing rules are exercised.
2. **"Data from 2018-07-01 to the latest available date."** The mock data ends on 2026-11-13. The open month (November 2026) is excluded from monthly returns because its last trading day hasn't happened yet. The month-end rule uses the last date with any price; exchange holidays aren't modelled separately.
3. **Customer's own Git repository.** The code is laid out as a repo (`sql/`, `dashboard/`, README), but it lives in this Snowsight workspace. Connecting the customer's GitHub needs their credentials: an API integration plus `CREATE GIT REPOSITORY`. After that, deploy with `EXECUTE IMMEDIATE FROM @repo/branches/main/sql/0X_*.sql`, and set `code_version` to the Git commit SHA.
4. **"Retried once" scope.** `TASK_AUTO_RETRY_ATTEMPTS = 1` retries the graph run from the failed task. It doesn't retry an isolated task while the rest carry on. That is the behaviour the spec describes, but the mechanism is graph-level.
5. **Code version tied to a run.** Each stage records the `code_version` label from the config and the SHA-256 of the exact procedure DDL it ran. A Git commit SHA needs item 3.
6. **"Input snapshot."** Stage 2 snapshots `PRICES` per run (`PRICES_HIST`). The upstream share itself can't be snapshotted. A zero-copy clone of a shared database isn't possible, so per-run `PRICES_HIST` is the input snapshot.
7. **Ties.** `RANK` uses SQL `RANK()` (ties share a rank). MOMENTUM selection breaks a tie at the cut-off by ticker so the 16 names are deterministic. The spec doesn't define tie handling.
8. **Benchmark with a data gap.** BENCHMARK holds all 49 at 1/49. If a holding has no `RET_M` in the holding month, the portfolio return averages the holdings that have one. The same applies to MOMENTUM.
9. **R.** Not built. Everything here is SQL. See the open questions below.
10. **Cost.** Measured at PoC scale and at 3,000 synthetic stocks (§10). The figures use list prices from third-party summaries of Snowflake's pricing guide, not this account's contract. Metered credits (§10 Report 3) only appear about 3 hours after a run. Costs for more signals are extrapolated, and the dashboard's compute pool cost isn't quantified.
11. **30-minute walkthrough.** A person has to give this; it isn't something code can deliver.

## 8. Answers to the spec's open questions (short form)

- **Orchestration:** Snowflake **task graphs**, because they are native: CRON plus on-demand, CONFIG parameters, dependencies declared in code, auto-retry, a finalizer, graph-view history, and no extra infrastructure. dbt Projects on Snowflake would also fit and could be scheduled by the same tasks. An external orchestrator (Airflow) is only worth adding if Snowflake is one step in a wider workflow.
- **R:** run the existing R scripts as containers in **Snowpark Container Services** (job services from a task). They reach the data through the Snowflake ODBC/ADBC driver with the service's OAuth token, so nothing is exported. Not demonstrated here.
- **CapIQ share update time and completeness:** S&P Global publishes the update schedule and SLA for XpressFeed; we haven't confirmed it here. A completeness gate can be added to Stage 2 (for example, require all 49 tickers on the latest date, or check a load-control table if S&P provides one) before the stage succeeds.
- **Versioning outputs:** per-run snapshot tables (`<TABLE>_HIST`, tagged `RUN_ID`), plus content hashes in `STAGE_RUNS`, plus Time Travel. Zero-copy `CLONE` per run is an alternative for big tables, but it isn't built here.
- **Cost:** measured, not guessed. See §10. In short, compute costs about **$0.09 per full run** at both PoC scale and 3,000 stocks (Enterprise list price), and a realistic month is **a few dollars** before the CapIQ licence.
- **Own Git repo:** yes (see §7 item 3).

## 9. Extending (researchers)

- **New signal:** copy `04_signal.sql` to a new stage procedure, add a task `AFTER T03_RETURNS`, and register its output tables in the `CASE` lists in `SP_RUN_STAGE`.
- **New universe:** edit `ETF_UNIVERSE` (it's a table, not code) and rerun. Stage 2 fails clearly if a ticker has no CapIQ prices.

## 10. Cost: measured test and list-price estimate

**Pricing basis:** on-demand **list** prices, **no capacity or tier discount**, AWS US West 2 (this account). Credits cost **$2.00 Standard / $3.00 Enterprise / $4.00 Business Critical**, and storage costs **$23 per TB per month**. These rates come from third-party summaries of Snowflake's pricing guide (checked Nov 2026). One source puts Oregon 12.5% above US East, so confirm them against Snowflake's Service Consumption Table or your Order Form before quoting. X-Small = 1 credit/hr and Small = 2 credits/hr (standard Gen1 warehouse).

**Test setup:** the pipeline runs on its own warehouse, **`ETF_POC_WH`** (X-Small, `AUTO_SUSPEND = 60s`), so that warehouse's meter is this pipeline's cost. The scripts are `sql/09_cost_test.sql` (views `COST_BY_STAGE`, `COST_BY_RUN` and `LIST_PRICES`, plus four reports) and `sql/10_scale_test.sql` (a 3,000-stock setup and teardown). The cost per run is billed time: run wall-clock time plus the 60-second auto-suspend tail.

### Test A: PoC as specified (49 ETFs), 3 runs on X-Small, measured 2026-11-15

| Stage | Median seconds | Credits | $ Std | $ Ent | $ BC |
|---|---|---|---|---|---|
| 1 UNIVERSE | 3.1 | 0.00087 | 0.002 | 0.003 | 0.003 |
| 2 INGEST | 3.8 | 0.00106 | 0.002 | 0.003 | 0.004 |
| 3 RETURNS | 5.8 | 0.00160 | 0.003 | 0.005 | 0.006 |
| 4 SIGNAL | 3.4 | 0.00095 | 0.002 | 0.003 | 0.004 |
| 5 PORTFOLIOS | 5.5 | 0.00152 | 0.003 | 0.005 | 0.006 |
| 6 PERFORMANCE | 5.0 | 0.00139 | 0.003 | 0.004 | 0.006 |
| **Full run, billed** (41–43 s wall + 60 s tail) | | **~0.028** | **$0.06** | **$0.09** | **$0.11** |

### Test B: customer's target scale (3,049 tickers, 6.66M daily prices, 2018–2026)

| Warehouse | Wall time | Billed credits | $ Std | $ Ent | $ BC |
|---|---|---|---|---|---|
| X-Small | 47 s | 0.030 | $0.06 | $0.09 | $0.12 |
| Small | 50 s | 0.061 | $0.12 | $0.18 | $0.24 |

**Findings:**
- **62 times the data costs only about 7% more.** The runtime is dominated by fixed per-step overhead (task hand-offs, logging, content hashes, snapshots), not by the maths.
- **A bigger warehouse doesn't help at this size.** Small cost twice as much and finished no faster. Keep X-Small.

### Monthly estimate (list price, no discount)

| Scenario | Runs/month | Credits | $ Std | $ Ent | $ BC |
|---|---|---|---|---|---|
| PoC: 1 scheduled + 20 manual reruns | 21 | 0.59 | $1.18 | $1.76 | $2.35 |
| 3,000 stocks, 1 signal, same cadence | 21 | 0.63 | $1.26 | $1.89 | $2.52 |
| 3,000 stocks, **10 signals** (extrapolated*) | 21 | 1.34 | $2.67 | $4.01 | $5.34 |
| 3,000 stocks, 10 signals, **run daily** + 20 reruns (extrapolated*) | 50 | 3.2 | $6.40 | $9.60 | $12.80 |

\*Each extra signal adds one SIGNAL + PORTFOLIOS + PERFORMANCE pass, measured at ~13.6 s on X-Small at 3,000 stocks. That makes a 10-signal run about 229 s billed, or 0.064 credits. This is an extrapolation, not a measured run.

**Storage:** at 3,000 stocks, the current output tables are about 140 MB, and each run adds about 140 MB of `_HIST` snapshots. 21 runs a month is about 3 GB per month, so after a year (~35 GB) storage is about **$0.80 per month**. At PoC scale it's about $0.001 per month. Delete old `_HIST` rows if you don't need every run kept.

**Not included / not measured:**
- **Dashboard:** the Streamlit container is billed on compute pool `SYSTEM_COMPUTE_POOL_CPU` while the app is open. Instance-family rates are in the Service Consumption Table, and the pool is shared here, so this isn't quantified. A warehouse-runtime Streamlit or a native Snowsight dashboard would instead bill on `ETF_POC_WH` only while it queries.
- **Cloud services:** these are free up to 10% of daily compute, and this workload is well under that.
- **CapIQ licence:** S&P's fee for the data. Reading a share in the same region has no Snowflake transfer cost.
- **Cortex Code / AI usage:** billed separately in AI credits.
- **R in containers:** not built (see §8).

**Verify with actual billing** about 3 hours after any run (`09_cost_test.sql`, Report 3):
```sql
SELECT DATE_TRUNC('day', START_TIME) DAY, SUM(CREDITS_USED_COMPUTE) CREDITS,
       ROUND(SUM(CREDITS_USED_COMPUTE) * 3, 2) USD_ENTERPRISE
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE WAREHOUSE_NAME = 'ETF_POC_WH' GROUP BY 1 ORDER BY 1 DESC;
```
Note: Snowflake bills a **60-second minimum each time the warehouse resumes**. Today's back-to-back test runs may meter slightly differently from isolated monthly runs.

**Rerun the test yourself:**
1. Run the full pipeline three times (Test A).
2. Run the setup part of `sql/10_scale_test.sql`, run the pipeline, then optionally `ALTER WAREHOUSE ETF_POC_WH SET WAREHOUSE_SIZE = SMALL` and run again with `"warehouse_credits_per_hour": 2` in the config (Test B).
3. Run the teardown part and resize back to X-Small.
4. Read Reports 1–4 in `09_cost_test.sql`.
