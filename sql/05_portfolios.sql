-- =====================================================================
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
