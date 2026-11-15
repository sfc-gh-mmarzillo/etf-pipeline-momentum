-- =====================================================================
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
