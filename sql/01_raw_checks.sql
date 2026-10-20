-- =====================================================================
-- 01_raw_checks.sql  |  Checks on RAW.LC_LOANS_RAW after load
-- Run each section on its own (Snowsight: one SQL file per check).
-- =====================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

-- ---------------------------------------------------------------------
-- 1. Source (pandas profile) vs RAW reconciliation: 8 controls, $1 tolerance
--    Result on first load: 8/8 PASS. Only variance: $0.31 on $27.3B TOTAL_PYMNT
--    (float summation in pandas vs exact decimal in Snowflake).
-- ---------------------------------------------------------------------
WITH b AS (SELECT MAX(_BATCH_ID) AS id FROM RAW.LC_LOANS_RAW),
r AS (SELECT * FROM RAW.LC_LOANS_RAW WHERE _BATCH_ID = (SELECT id FROM b)),
src AS (
  SELECT METRIC_NAME, METRIC_VALUE
  FROM AUDIT.SOURCE_PROFILE
  WHERE BATCH_ID = (SELECT id FROM b)
),
tgt AS (
  SELECT 'ROW_COUNT' AS m, COUNT(*)::NUMBER(38,4) AS v FROM r
  UNION ALL SELECT 'DISTINCT_ID',         COUNT(DISTINCT ID)                     FROM r
  UNION ALL SELECT 'NON_NUMERIC_ID_ROWS', COUNT_IF(TRY_TO_NUMBER(ID) IS NULL)    FROM r
  UNION ALL SELECT 'SUM_LOAN_AMNT',       SUM(TRY_TO_NUMBER(LOAN_AMNT, 38, 2))   FROM r
  UNION ALL SELECT 'SUM_FUNDED_AMNT',     SUM(TRY_TO_NUMBER(FUNDED_AMNT, 38, 2)) FROM r
  UNION ALL SELECT 'SUM_OUT_PRNCP',       SUM(TRY_TO_NUMBER(OUT_PRNCP, 38, 2))   FROM r
  UNION ALL SELECT 'SUM_TOTAL_PYMNT',     SUM(TRY_TO_NUMBER(TOTAL_PYMNT, 38, 2)) FROM r
  UNION ALL SELECT 'SUM_RECOVERIES',      SUM(TRY_TO_NUMBER(RECOVERIES, 38, 2))  FROM r
)
SELECT
  t.m                                                  AS CHECK_NAME,
  s.METRIC_VALUE                                       AS SOURCE_VALUE,
  t.v                                                  AS RAW_VALUE,
  t.v - s.METRIC_VALUE                                 AS DIFF,
  IFF(ABS(t.v - s.METRIC_VALUE) <= 1, 'PASS', 'FAIL') AS STATUS
FROM tgt t
LEFT JOIN src s ON s.METRIC_NAME = t.m
ORDER BY CHECK_NAME;

-- ---------------------------------------------------------------------
-- 2. Loan status mix (drives default / delinquency definitions)
-- ---------------------------------------------------------------------
SELECT
  LOAN_STATUS,
  COUNT(*)                                             AS LOANS,
  ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 2)    AS PCT_OF_LOANS,
  ROUND(SUM(TRY_TO_NUMBER(LOAN_AMNT, 38, 2)) / 1e9, 2) AS LOAN_AMNT_BILLIONS
FROM RAW.LC_LOANS_RAW
GROUP BY LOAN_STATUS
ORDER BY LOANS DESC;

-- ---------------------------------------------------------------------
-- 3. Volume by origination year (junk rows excluded)
-- ---------------------------------------------------------------------
SELECT
  YEAR(TRY_TO_DATE(ISSUE_D, 'MON-YYYY'))               AS ISSUE_YEAR,
  COUNT(*)                                             AS LOANS,
  ROUND(SUM(TRY_TO_NUMBER(LOAN_AMNT, 38, 2)) / 1e9, 2) AS LOAN_AMNT_BILLIONS,
  ROUND(AVG(TRY_TO_NUMBER(LOAN_AMNT, 38, 2)), 0)       AS AVG_LOAN_SIZE
FROM RAW.LC_LOANS_RAW
WHERE TRY_TO_NUMBER(ID) IS NOT NULL
GROUP BY ISSUE_YEAR
ORDER BY ISSUE_YEAR;

-- ---------------------------------------------------------------------
-- 4. Data quality on columns the marts depend on
--    Result on first load: 0 everywhere except NULL_ANNUAL_INC = 4, NULL_DTI = 1,711
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                                                    AS TOTAL_LOANS,
  COUNT_IF(LOAN_AMNT   IS NULL)                                               AS NULL_LOAN_AMNT,
  COUNT_IF(ISSUE_D     IS NULL)                                               AS NULL_ISSUE_D,
  COUNT_IF(LOAN_STATUS IS NULL)                                               AS NULL_LOAN_STATUS,
  COUNT_IF(GRADE       IS NULL)                                               AS NULL_GRADE,
  COUNT_IF(INT_RATE    IS NULL)                                               AS NULL_INT_RATE,
  COUNT_IF(ADDR_STATE  IS NULL)                                               AS NULL_ADDR_STATE,
  COUNT_IF(PURPOSE     IS NULL)                                               AS NULL_PURPOSE,
  COUNT_IF(ANNUAL_INC  IS NULL)                                               AS NULL_ANNUAL_INC,
  COUNT_IF(DTI         IS NULL)                                               AS NULL_DTI,
  COUNT_IF(INT_RATE IS NOT NULL AND TRY_TO_NUMBER(INT_RATE, 10, 4) IS NULL)   AS BAD_INT_RATE,
  COUNT_IF(ISSUE_D  IS NOT NULL AND TRY_TO_DATE(ISSUE_D, 'MON-YYYY') IS NULL) AS BAD_ISSUE_D,
  COUNT_IF(TRY_TO_NUMBER(LOAN_AMNT, 38, 2) <= 0)                              AS NON_POSITIVE_LOAN_AMNT
FROM RAW.LC_LOANS_RAW
WHERE TRY_TO_NUMBER(ID) IS NOT NULL;

-- Load log for reference
SELECT * FROM AUDIT.LOAD_LOG ORDER BY LOADED_AT DESC;
