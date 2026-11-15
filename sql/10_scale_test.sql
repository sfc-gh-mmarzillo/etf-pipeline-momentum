-- =====================================================================
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
