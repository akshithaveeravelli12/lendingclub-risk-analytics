-- =====================================================================
-- 05_kpis.sql  |  Risk KPI views in MARTS (read by Power BI)
-- Definitions:
--   Charge-off rate   = charged-off loans / resolved loans (Fully Paid + Charged Off)
--   Delinquency rate  = delinquent loans (grace, late, default) / active loans
--   30+ DPD rate      = loans 31+ days past due or in default / active loans
--   Net loss rate     = net charge-offs / funded amount, resolved loans
--   Recovery rate     = recoveries / gross charge-offs, bad loans
-- =====================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

-- ---------------------------------------------------------------------
-- 3a. Portfolio headline KPIs
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MARTS.VW_PORTFOLIO_KPIS AS
SELECT
  COUNT(*)                                                         AS TOTAL_LOANS,
  SUM(FUNDED_AMNT)                                                 AS FUNDED_AMNT,
  SUM(IFF(NOT IS_RESOLVED, OUT_PRNCP, 0))                          AS OUTSTANDING_PRINCIPAL,

  COUNT_IF(IS_RESOLVED)                                            AS RESOLVED_LOANS,
  COUNT_IF(LOAN_STATUS_GROUP = 'CHARGED_OFF')                      AS CHARGED_OFF_LOANS,
  ROUND(100 * CHARGED_OFF_LOANS / NULLIF(RESOLVED_LOANS, 0), 2)    AS CHARGE_OFF_RATE_PCT,

  COUNT_IF(NOT IS_RESOLVED)                                        AS ACTIVE_LOANS,
  COUNT_IF(IS_DELINQUENT)                                          AS DELINQUENT_LOANS,
  ROUND(100 * DELINQUENT_LOANS / NULLIF(ACTIVE_LOANS, 0), 2)       AS DELINQUENCY_RATE_PCT,
  ROUND(100 * COUNT_IF(IS_30PLUS_DPD) / NULLIF(ACTIVE_LOANS, 0), 2) AS DPD30_RATE_PCT,
  ROUND(100 * SUM(IFF(IS_DELINQUENT, OUT_PRNCP, 0))
            / NULLIF(OUTSTANDING_PRINCIPAL, 0), 2)                 AS DELINQUENT_BALANCE_PCT,

  SUM(GROSS_CHARGE_OFF_AMNT)                                       AS GROSS_CHARGE_OFF_AMNT,
  SUM(IFF(IS_BAD, RECOVERIES, 0))                                  AS RECOVERIES_AMNT,
  SUM(NET_CHARGE_OFF_AMNT)                                         AS NET_CHARGE_OFF_AMNT,
  ROUND(100 * SUM(IFF(IS_RESOLVED, NET_CHARGE_OFF_AMNT, 0))
            / NULLIF(SUM(IFF(IS_RESOLVED, FUNDED_AMNT, 0)), 0), 2) AS NET_LOSS_RATE_PCT,
  ROUND(100 * RECOVERIES_AMNT / NULLIF(SUM(GROSS_CHARGE_OFF_AMNT), 0), 2) AS RECOVERY_RATE_PCT,
  ROUND(AVG(INT_RATE_PCT), 2)                                      AS AVG_INT_RATE_PCT
FROM MARTS.FCT_LOAN;

SELECT * FROM MARTS.VW_PORTFOLIO_KPIS;

-- ---------------------------------------------------------------------
-- 3b. Risk and pricing by segment (grade, purpose, term) vs portfolio
--     Realized return = (total paid - funded) / funded, resolved loans, lifetime (not annualized)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MARTS.VW_RISK_BY_SEGMENT AS
SELECT
  CASE
    WHEN GROUPING(GRADE) = 0       THEN 'GRADE'
    WHEN GROUPING(PURPOSE) = 0     THEN 'PURPOSE'
    WHEN GROUPING(TERM_MONTHS) = 0 THEN 'TERM'
    ELSE 'PORTFOLIO'
  END                                                                   AS SEGMENT_TYPE,
  COALESCE(GRADE, PURPOSE, TERM_MONTHS::VARCHAR || ' months', 'ALL')    AS SEGMENT,
  COUNT(*)                                                              AS LOANS,
  ROUND(SUM(FUNDED_AMNT) / 1e6, 1)                                      AS FUNDED_MILLIONS,
  ROUND(AVG(INT_RATE_PCT), 2)                                           AS AVG_INT_RATE_PCT,
  COUNT_IF(IS_RESOLVED)                                                 AS RESOLVED_LOANS,
  ROUND(100 * COUNT_IF(LOAN_STATUS_GROUP = 'CHARGED_OFF')
            / NULLIF(COUNT_IF(IS_RESOLVED), 0), 2)                      AS CHARGE_OFF_RATE_PCT,
  ROUND(100 * SUM(IFF(IS_RESOLVED, NET_CHARGE_OFF_AMNT, 0))
            / NULLIF(SUM(IFF(IS_RESOLVED, FUNDED_AMNT, 0)), 0), 2)      AS NET_LOSS_RATE_PCT,
  ROUND(100 * (SUM(IFF(IS_RESOLVED, TOTAL_PYMNT, 0)) - SUM(IFF(IS_RESOLVED, FUNDED_AMNT, 0)))
            / NULLIF(SUM(IFF(IS_RESOLVED, FUNDED_AMNT, 0)), 0), 2)      AS REALIZED_RETURN_PCT,
  ROUND(100 * COUNT_IF(IS_DELINQUENT)
            / NULLIF(COUNT_IF(NOT IS_RESOLVED), 0), 2)                  AS DELINQUENCY_RATE_PCT
FROM MARTS.FCT_LOAN
GROUP BY GROUPING SETS ((GRADE), (PURPOSE), (TERM_MONTHS), ());

SELECT *
FROM MARTS.VW_RISK_BY_SEGMENT
ORDER BY SEGMENT_TYPE, CHARGE_OFF_RATE_PCT DESC;

-- ---------------------------------------------------------------------
-- 3c. Vintage curves: cumulative bad rate by months on book (MOB)
--     Default timing proxy = months from issue to last payment (bad loans).
--     A MOB point is shown only if the whole vintage (through Dec) has reached it
--     by the data snapshot (latest last-payment date).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MARTS.VW_VINTAGE_CURVES AS
WITH snap AS (
  SELECT MAX(d.DATE_DAY) AS SNAPSHOT_DATE
  FROM MARTS.FCT_LOAN f
  JOIN MARTS.DIM_DATE d ON d.DATE_KEY = f.LAST_PYMNT_DATE_KEY
),
loans AS (
  SELECT
    f.VINTAGE_YEAR,
    f.IS_BAD,
    COALESCE(DATEDIFF(MONTH, di.DATE_DAY, dl.DATE_DAY), 0) AS MOB_AT_LAST_PYMNT
  FROM MARTS.FCT_LOAN f
  JOIN MARTS.DIM_DATE di      ON di.DATE_KEY = f.ISSUE_DATE_KEY
  LEFT JOIN MARTS.DIM_DATE dl ON dl.DATE_KEY = f.LAST_PYMNT_DATE_KEY
),
mob AS (
  SELECT column1 AS MOB FROM VALUES (3), (6), (9), (12), (18), (24), (30), (36), (48), (60)
),
vint AS (
  SELECT VINTAGE_YEAR, COUNT(*) AS VINTAGE_LOANS FROM loans GROUP BY VINTAGE_YEAR
)
SELECT
  v.VINTAGE_YEAR,
  m.MOB,
  v.VINTAGE_LOANS,
  COUNT_IF(l.IS_BAD AND l.MOB_AT_LAST_PYMNT <= m.MOB)                     AS CUM_BAD_LOANS,
  ROUND(100 * COUNT_IF(l.IS_BAD AND l.MOB_AT_LAST_PYMNT <= m.MOB)
            / v.VINTAGE_LOANS, 2)                                         AS CUM_BAD_RATE_PCT
FROM vint v
CROSS JOIN mob m
CROSS JOIN snap s
JOIN loans l ON l.VINTAGE_YEAR = v.VINTAGE_YEAR
WHERE m.MOB <= DATEDIFF(MONTH, DATE_FROM_PARTS(v.VINTAGE_YEAR, 12, 1), s.SNAPSHOT_DATE)
GROUP BY v.VINTAGE_YEAR, m.MOB, v.VINTAGE_LOANS;

-- Readable grid: one row per vintage, one column per month-on-book
SELECT *
FROM (SELECT VINTAGE_YEAR, MOB, CUM_BAD_RATE_PCT FROM MARTS.VW_VINTAGE_CURVES)
PIVOT (MAX(CUM_BAD_RATE_PCT) FOR MOB IN (6, 12, 18, 24, 36, 48, 60))
  AS p (VINTAGE_YEAR, MOB_6, MOB_12, MOB_18, MOB_24, MOB_36, MOB_48, MOB_60)
ORDER BY VINTAGE_YEAR;
