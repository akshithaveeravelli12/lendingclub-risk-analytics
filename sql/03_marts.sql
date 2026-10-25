-- =====================================================================
-- 03_marts.sql  |  Star schema in MARTS: DIM_DATE, DIM_BORROWER, FCT_LOAN
-- =====================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

-- ---------------------------------------------------------------------
-- DIM_DATE: daily calendar 2007-01-01 to 2020-12-31 (5,114 days)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MARTS.DIM_DATE AS
WITH d AS (
  SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2007-01-01'::DATE) AS DATE_DAY
  FROM TABLE(GENERATOR(ROWCOUNT => 5114))
)
SELECT
  TO_NUMBER(TO_CHAR(DATE_DAY, 'YYYYMMDD'))  AS DATE_KEY,
  DATE_DAY,
  YEAR(DATE_DAY)                            AS CAL_YEAR,
  QUARTER(DATE_DAY)                         AS CAL_QUARTER,
  MONTH(DATE_DAY)                           AS CAL_MONTH,
  MONTHNAME(DATE_DAY)                       AS MONTH_NAME,
  TO_CHAR(DATE_DAY, 'YYYY-MM')              AS YEAR_MONTH,
  YEAR(DATE_DAY) || '-Q' || QUARTER(DATE_DAY) AS YEAR_QUARTER,
  DATE_TRUNC('MONTH', DATE_DAY)             AS MONTH_START,
  DAYNAME(DATE_DAY)                         AS DAY_NAME,
  DAY(DATE_DAY) = 1                         AS IS_MONTH_START
FROM d;

-- Check
SELECT
  COUNT(*)                 AS DAYS,
  COUNT(DISTINCT DATE_KEY) AS DISTINCT_KEYS,
  MIN(DATE_DAY)            AS FIRST_DAY,
  MAX(DATE_DAY)            AS LAST_DAY,
  COUNT_IF(IS_MONTH_START) AS MONTHS
FROM MARTS.DIM_DATE;

-- ---------------------------------------------------------------------
-- DIM_BORROWER: borrower profile at origination, 1:1 with loan
-- (LendingClub anonymizes member ids, so the borrower key is the loan id)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MARTS.DIM_BORROWER AS
SELECT
  LOAN_ID                                            AS BORROWER_KEY,
  EMP_TITLE,
  EMP_LENGTH_YEARS,
  CASE
    WHEN EMP_LENGTH_YEARS IS NULL THEN 'Unknown'
    WHEN EMP_LENGTH_YEARS < 2     THEN 'Under 2 yrs'
    WHEN EMP_LENGTH_YEARS < 5     THEN '2 to 4 yrs'
    WHEN EMP_LENGTH_YEARS < 10    THEN '5 to 9 yrs'
    ELSE '10+ yrs'
  END                                                AS EMP_LENGTH_BAND,
  HOME_OWNERSHIP,
  ANNUAL_INC,
  CASE
    WHEN ANNUAL_INC IS NULL  THEN 'Unknown'
    WHEN ANNUAL_INC < 40000  THEN 'Under 40K'
    WHEN ANNUAL_INC < 75000  THEN '40K to 75K'
    WHEN ANNUAL_INC < 120000 THEN '75K to 120K'
    ELSE '120K+'
  END                                                AS INCOME_BAND,
  VERIFICATION_STATUS,
  ADDR_STATE,
  ZIP3,
  DTI,
  CASE
    WHEN DTI IS NULL THEN 'Unknown'
    WHEN DTI < 10    THEN 'Under 10'
    WHEN DTI < 20    THEN '10 to 20'
    WHEN DTI < 30    THEN '20 to 30'
    ELSE '30+'
  END                                                AS DTI_BAND,
  FICO_MID,
  CASE
    WHEN FICO_MID IS NULL THEN 'Unknown'
    WHEN FICO_MID < 660   THEN 'Under 660'
    WHEN FICO_MID < 700   THEN '660 to 699'
    WHEN FICO_MID < 740   THEN '700 to 739'
    ELSE '740+'
  END                                                AS FICO_BAND,
  EARLIEST_CR_LINE_DATE,
  DATEDIFF(YEAR, EARLIEST_CR_LINE_DATE, ISSUE_DATE)  AS CREDIT_HISTORY_YEARS,
  DELINQ_2YRS,
  INQ_LAST_6MTHS,
  OPEN_ACC,
  PUB_REC,
  REVOL_BAL,
  REVOL_UTIL_PCT,
  TOTAL_ACC
FROM STAGING.STG_LOANS;

-- Check: FICO band mix and bad rate on resolved loans
SELECT
  COALESCE(b.FICO_BAND, 'TOTAL')                                         AS FICO_BAND,
  COUNT(*)                                                               AS BORROWERS,
  ROUND(AVG(b.ANNUAL_INC), 0)                                            AS AVG_INCOME,
  ROUND(100 * COUNT_IF(s.IS_BAD AND s.IS_RESOLVED) / NULLIF(COUNT_IF(s.IS_RESOLVED), 0), 2) AS CHARGE_OFF_RATE_PCT
FROM MARTS.DIM_BORROWER b
JOIN STAGING.STG_LOANS s ON s.LOAN_ID = b.BORROWER_KEY
GROUP BY ROLLUP (b.FICO_BAND)
ORDER BY FICO_BAND;

-- ---------------------------------------------------------------------
-- FCT_LOAN: one row per loan; keys to DIM_BORROWER and DIM_DATE
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MARTS.FCT_LOAN AS
SELECT
  LOAN_ID,
  LOAN_ID                                          AS BORROWER_KEY,
  TO_NUMBER(TO_CHAR(ISSUE_DATE, 'YYYYMMDD'))       AS ISSUE_DATE_KEY,
  TO_NUMBER(TO_CHAR(LAST_PYMNT_DATE, 'YYYYMMDD'))  AS LAST_PYMNT_DATE_KEY,
  ISSUE_YEAR                                       AS VINTAGE_YEAR,

  GRADE,
  SUB_GRADE,
  PURPOSE,
  TERM_MONTHS,
  APPLICATION_TYPE,
  LOAN_STATUS_GROUP,
  MEETS_CREDIT_POLICY,
  IS_RESOLVED,
  IS_BAD,
  IS_DELINQUENT,
  IS_30PLUS_DPD,

  LOAN_AMNT,
  FUNDED_AMNT,
  INT_RATE_PCT,
  INSTALLMENT,
  OUT_PRNCP,
  TOTAL_PYMNT,
  TOTAL_REC_PRNCP,
  TOTAL_REC_INT,
  RECOVERIES,
  GROSS_CHARGE_OFF_AMNT,
  NET_CHARGE_OFF_AMNT,

  _BATCH_ID
FROM STAGING.STG_LOANS;

-- Check: row count, totals, and orphan keys (should be 0)
SELECT
  COUNT(*)                                     AS FACT_ROWS,
  COUNT(DISTINCT f.LOAN_ID)                    AS DISTINCT_LOANS,
  ROUND(SUM(f.LOAN_AMNT) / 1e9, 3)             AS LOAN_AMNT_BILLIONS,
  ROUND(SUM(f.NET_CHARGE_OFF_AMNT) / 1e6, 1)   AS NET_CHARGE_OFF_MILLIONS,
  COUNT_IF(b.BORROWER_KEY IS NULL)             AS ORPHAN_BORROWER,
  COUNT_IF(d.DATE_KEY IS NULL)                 AS ORPHAN_ISSUE_DATE
FROM MARTS.FCT_LOAN f
LEFT JOIN MARTS.DIM_BORROWER b ON b.BORROWER_KEY = f.BORROWER_KEY
LEFT JOIN MARTS.DIM_DATE     d ON d.DATE_KEY     = f.ISSUE_DATE_KEY;
