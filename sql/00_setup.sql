-- =====================================================================
-- 00_setup.sql : database, schemas, universe and MOCK CapIQ XpressFeed
-- ---------------------------------------------------------------------
-- MOCK DATA NOTICE: this account has no S&P XpressFeed share, so the
-- XPRESSFEED schema below is a synthetic stand-in with the SAME table and
-- column names the spec uses (CIQTRADINGITEM, CIQPRICEEQUITY). Prices are
-- deterministic synthetic random walks, NOT real market data.
-- To go live: point the PRICES ingest at SPGLOBAL.XPRESSFEED (pipeline
-- config key "source_db"), nothing else changes.
-- =====================================================================
CREATE DATABASE IF NOT EXISTS ETF_MOMENTUM_POC;
CREATE SCHEMA IF NOT EXISTS ETF_MOMENTUM_POC.XPRESSFEED COMMENT = 'MOCK of SPGLOBAL.XPRESSFEED (synthetic prices)';
CREATE SCHEMA IF NOT EXISTS ETF_MOMENTUM_POC.PIPELINE   COMMENT = 'ETF 12-1 momentum pipeline: stage outputs, run log, tasks';

-- ---------------- Universe (customer-provided table) -----------------
CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE (TICKER STRING NOT NULL, GROUP_NAME STRING NOT NULL);
INSERT INTO ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE
SELECT t.value::STRING, g.grp
FROM (SELECT 'Broad equity indices' grp, ARRAY_CONSTRUCT('SPY','IWM','EFA','EEM','QQQ','MDY') tk UNION ALL
      SELECT 'Sector SPDRs', ARRAY_CONSTRUCT('XLK','XLF','XLI','XLE','XLU','XLB','XLY','XLP','XLV','XLC') UNION ALL
      SELECT 'Industry and thematic', ARRAY_CONSTRUCT('KBE','KRE','XRT','SOXX','XBI','IBB','IHI','XHB','ITB','XOP','OIH','XME','GDX','VNQ','IYR','IYT','IGV','CIBR','ITA','IYZ','KIE','JETS') UNION ALL
      SELECT 'Commodities', ARRAY_CONSTRUCT('GLD','SLV','USO','DBA','DBB','DBC') UNION ALL
      SELECT 'Currencies', ARRAY_CONSTRUCT('FXE','FXY','FXA','FXB','UUP')) g,
     LATERAL FLATTEN(g.tk) t;

-- ---------------- Mock CIQTRADINGITEM --------------------------------
-- One primary (PRIMARYFLAG=1) trading item per ticker, plus a decoy
-- non-primary listing to prove the PRIMARYFLAG filter matters.
CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM AS
SELECT 1000000 + ROW_NUMBER() OVER (ORDER BY TICKER) AS TRADINGITEMID, TICKER AS TICKERSYMBOL, 1 AS PRIMARYFLAG
FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE
UNION ALL
SELECT 2000000 + ROW_NUMBER() OVER (ORDER BY TICKER), TICKER, 0
FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE;

-- ---------------- Mock CIQPRICEEQUITY --------------------------------
-- Weekday calendar 2018-06-01 .. 2026-11-13. Daily log return =
--   beta*market factor + ticker/year drift + idiosyncratic noise,
-- all from HASH-based Box-Muller draws so the data is fully deterministic.
-- ~0.2% of ticker-days are dropped (data gaps) and a few rows carry NULL/0
-- closes, to exercise the spec's gap and "drop non-positive close" rules.
CREATE OR REPLACE TABLE ETF_MOMENTUM_POC.XPRESSFEED.CIQPRICEEQUITY AS
WITH days AS (
  SELECT d FROM (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2018-06-01'::DATE) AS d
                 FROM TABLE(GENERATOR(ROWCOUNT => 3200)))
  WHERE d <= '2026-11-13' AND DAYOFWEEKISO(d) <= 5
),
params AS (
  SELECT u.TICKER, u.GROUP_NAME, ti.TRADINGITEMID,
         CASE u.GROUP_NAME WHEN 'Broad equity indices' THEN 1.0 WHEN 'Sector SPDRs' THEN 0.95
              WHEN 'Industry and thematic' THEN 1.2 WHEN 'Commodities' THEN 0.3 ELSE 0.05 END AS beta,
         CASE u.GROUP_NAME WHEN 'Broad equity indices' THEN 0.006 WHEN 'Sector SPDRs' THEN 0.009
              WHEN 'Industry and thematic' THEN 0.014 WHEN 'Commodities' THEN 0.014 ELSE 0.004 END AS idio_vol,
         20 + MOD(ABS(HASH(u.TICKER)), 400) AS p0
  FROM ETF_MOMENTUM_POC.PIPELINE.ETF_UNIVERSE u
  JOIN ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM ti ON ti.TICKERSYMBOL = u.TICKER AND ti.PRIMARYFLAG = 1
),
mkt AS (
  SELECT d, 0.0005 + 0.0011 * SQRT(-2*LN((MOD(ABS(HASH('MKT',d,1)),1000000)+0.5)/1e6)) * COS(2*PI()*(MOD(ABS(HASH('MKT',d,2)),1000000)+0.5)/1e6) * 10 AS f
  FROM days
),
raw AS (
  SELECT p.TRADINGITEMID, p.TICKER, k.d,
         p.p0,
         p.beta * m.f
         + 0.0008 * ((MOD(ABS(HASH(p.TICKER, YEAR(k.d), QUARTER(k.d))),1000000)/1e6) - 0.45)
         + p.idio_vol * SQRT(-2*LN((MOD(ABS(HASH(p.TICKER,k.d,1)),1000000)+0.5)/1e6)) * COS(2*PI()*(MOD(ABS(HASH(p.TICKER,k.d,2)),1000000)+0.5)/1e6) AS lr
  FROM params p CROSS JOIN days k JOIN mkt m ON m.d = k.d
),
px AS (
  SELECT TRADINGITEMID, TICKER, d,
         ROUND(p0 * EXP(SUM(lr) OVER (PARTITION BY TRADINGITEMID ORDER BY d ROWS UNBOUNDED PRECEDING)), 4) AS close_px,
         MOD(ABS(HASH(TICKER, d, 'gap')), 1000) AS gap_draw,
         MOD(ABS(HASH(TICKER, d, 'bad')), 5000) AS bad_draw
  FROM raw
)
SELECT TRADINGITEMID,
       d::TIMESTAMP_NTZ AS PRICINGDATE,
       CASE WHEN bad_draw = 0 THEN NULL WHEN bad_draw = 1 THEN 0 ELSE close_px END AS PRICECLOSE,
       100000 + MOD(ABS(HASH(TICKER, d, 'vol')), 5000000) AS VOLUME
FROM px
WHERE gap_draw >= 2                       -- ~0.2% gaps
UNION ALL                                 -- decoy non-primary listings (must be ignored)
SELECT ti.TRADINGITEMID, p.PRICINGDATE, p.PRICECLOSE * 1.37, p.VOLUME
FROM ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM ti
JOIN ETF_MOMENTUM_POC.XPRESSFEED.CIQTRADINGITEM tp ON tp.TICKERSYMBOL = ti.TICKERSYMBOL AND tp.PRIMARYFLAG = 1
JOIN (SELECT TRADINGITEMID, d::TIMESTAMP_NTZ AS PRICINGDATE, close_px AS PRICECLOSE, 1000 AS VOLUME FROM px) p
  ON p.TRADINGITEMID = tp.TRADINGITEMID
WHERE ti.PRIMARYFLAG = 0;
