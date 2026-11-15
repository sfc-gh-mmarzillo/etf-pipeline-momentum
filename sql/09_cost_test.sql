-- =====================================================================
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
