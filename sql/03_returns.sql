-- =====================================================================
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
