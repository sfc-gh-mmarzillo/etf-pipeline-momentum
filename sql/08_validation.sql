-- =====================================================================
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
