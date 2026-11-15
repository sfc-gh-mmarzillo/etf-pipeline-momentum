-- =====================================================================
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
