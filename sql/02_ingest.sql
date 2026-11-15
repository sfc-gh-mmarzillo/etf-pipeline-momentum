-- =====================================================================
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
