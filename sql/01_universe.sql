-- =====================================================================
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
