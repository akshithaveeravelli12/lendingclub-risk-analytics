-- =====================================================================
-- 02_staging.sql  |  RAW (all text) -> STAGING.STG_LOANS (typed, cleaned)
-- One row per real loan. Junk rows (non-numeric id) excluded; deduped on id.
-- =====================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

CREATE OR REPLACE TABLE STAGING.STG_LOANS AS
WITH src AS (
  SELECT *
  FROM RAW.LC_LOANS_RAW
  WHERE _BATCH_ID = (SELECT MAX(_BATCH_ID) FROM RAW.LC_LOANS_RAW)
    AND TRY_TO_NUMBER(ID) IS NOT NULL                       -- drops the 33 summary/footer rows
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ID ORDER BY _LOADED_AT DESC) = 1
)
SELECT
  -- Keys and dates
  TRY_TO_NUMBER(ID)                                        AS LOAN_ID,
  TRY_TO_DATE(ISSUE_D, 'MON-YYYY')                         AS ISSUE_DATE,
  YEAR(ISSUE_DATE)                                         AS ISSUE_YEAR,

  -- Loan terms
  TRY_TO_NUMBER(LOAN_AMNT, 12, 2)                          AS LOAN_AMNT,
  TRY_TO_NUMBER(FUNDED_AMNT, 12, 2)                        AS FUNDED_AMNT,
  TRY_TO_NUMBER(FUNDED_AMNT_INV, 12, 2)                    AS FUNDED_AMNT_INV,
  TRY_TO_NUMBER(REGEXP_SUBSTR(TERM, '[0-9]+'))             AS TERM_MONTHS,
  TRY_TO_NUMBER(REPLACE(INT_RATE, '%', ''), 6, 2)          AS INT_RATE_PCT,
  TRY_TO_NUMBER(INSTALLMENT, 12, 2)                        AS INSTALLMENT,
  GRADE,
  SUB_GRADE,
  PURPOSE,
  APPLICATION_TYPE,

  -- Status, grouped into risk buckets
  LOAN_STATUS                                              AS LOAN_STATUS_RAW,
  CASE
    WHEN LOAN_STATUS ILIKE '%Fully Paid'   THEN 'FULLY_PAID'
    WHEN LOAN_STATUS ILIKE '%Charged Off'  THEN 'CHARGED_OFF'
    WHEN LOAN_STATUS = 'Default'           THEN 'DEFAULT'
    WHEN LOAN_STATUS = 'Current'           THEN 'CURRENT'
    WHEN LOAN_STATUS = 'In Grace Period'   THEN 'GRACE_PERIOD'
    WHEN LOAN_STATUS = 'Late (16-30 days)' THEN 'LATE_16_30'
    WHEN LOAN_STATUS = 'Late (31-120 days)' THEN 'LATE_31_120'
    ELSE 'UNKNOWN'
  END                                                      AS LOAN_STATUS_GROUP,
  IFF(LOAN_STATUS ILIKE 'Does not meet%', FALSE, TRUE)     AS MEETS_CREDIT_POLICY,
  LOAN_STATUS_GROUP IN ('FULLY_PAID', 'CHARGED_OFF')       AS IS_RESOLVED,
  LOAN_STATUS_GROUP IN ('CHARGED_OFF', 'DEFAULT')          AS IS_BAD,
  LOAN_STATUS_GROUP IN ('GRACE_PERIOD', 'LATE_16_30', 'LATE_31_120', 'DEFAULT') AS IS_DELINQUENT,
  LOAN_STATUS_GROUP IN ('LATE_31_120', 'DEFAULT')          AS IS_30PLUS_DPD,

  -- Borrower
  NULLIF(TRIM(EMP_TITLE), '')                              AS EMP_TITLE,
  CASE
    WHEN EMP_LENGTH = '10+ years' THEN 10
    WHEN EMP_LENGTH = '< 1 year'  THEN 0
    ELSE TRY_TO_NUMBER(REGEXP_SUBSTR(EMP_LENGTH, '[0-9]+'))
  END                                                      AS EMP_LENGTH_YEARS,
  HOME_OWNERSHIP,
  TRY_TO_NUMBER(ANNUAL_INC, 14, 2)                         AS ANNUAL_INC,
  VERIFICATION_STATUS,
  ADDR_STATE,
  LEFT(ZIP_CODE, 3)                                        AS ZIP3,
  TRY_TO_NUMBER(DTI, 8, 2)                                 AS DTI,
  TRY_TO_NUMBER(FICO_RANGE_LOW)                            AS FICO_LOW,
  TRY_TO_NUMBER(FICO_RANGE_HIGH)                           AS FICO_HIGH,
  (FICO_LOW + FICO_HIGH) / 2                               AS FICO_MID,
  TRY_TO_DATE(EARLIEST_CR_LINE, 'MON-YYYY')                AS EARLIEST_CR_LINE_DATE,
  TRY_TO_NUMBER(DELINQ_2YRS)                               AS DELINQ_2YRS,
  TRY_TO_NUMBER(INQ_LAST_6MTHS)                            AS INQ_LAST_6MTHS,
  TRY_TO_NUMBER(OPEN_ACC)                                  AS OPEN_ACC,
  TRY_TO_NUMBER(PUB_REC)                                   AS PUB_REC,
  TRY_TO_NUMBER(REVOL_BAL, 14, 2)                          AS REVOL_BAL,
  TRY_TO_NUMBER(REPLACE(REVOL_UTIL, '%', ''), 6, 2)        AS REVOL_UTIL_PCT,
  TRY_TO_NUMBER(TOTAL_ACC)                                 AS TOTAL_ACC,

  -- Performance and losses
  TRY_TO_NUMBER(OUT_PRNCP, 12, 2)                          AS OUT_PRNCP,
  TRY_TO_NUMBER(TOTAL_PYMNT, 14, 2)                        AS TOTAL_PYMNT,
  TRY_TO_NUMBER(TOTAL_REC_PRNCP, 12, 2)                    AS TOTAL_REC_PRNCP,
  TRY_TO_NUMBER(TOTAL_REC_INT, 12, 2)                      AS TOTAL_REC_INT,
  TRY_TO_NUMBER(TOTAL_REC_LATE_FEE, 12, 2)                 AS TOTAL_REC_LATE_FEE,
  TRY_TO_NUMBER(RECOVERIES, 12, 2)                         AS RECOVERIES,
  TRY_TO_NUMBER(COLLECTION_RECOVERY_FEE, 12, 2)            AS COLLECTION_RECOVERY_FEE,
  TRY_TO_DATE(LAST_PYMNT_D, 'MON-YYYY')                    AS LAST_PYMNT_DATE,
  TRY_TO_NUMBER(LAST_PYMNT_AMNT, 12, 2)                    AS LAST_PYMNT_AMNT,
  IFF(IS_BAD,
      GREATEST(TRY_TO_NUMBER(src.FUNDED_AMNT, 12, 2) - TRY_TO_NUMBER(src.TOTAL_REC_PRNCP, 12, 2), 0),
      0)                                                   AS GROSS_CHARGE_OFF_AMNT,
  IFF(IS_BAD,
      GROSS_CHARGE_OFF_AMNT - (TRY_TO_NUMBER(src.RECOVERIES, 12, 2) - TRY_TO_NUMBER(src.COLLECTION_RECOVERY_FEE, 12, 2)),
      0)                                                   AS NET_CHARGE_OFF_AMNT,

  -- Lineage
  _BATCH_ID,
  _SOURCE_ROW_NUMBER,
  _LOADED_AT
FROM src;

-- Check: loans by status group, with a TOTAL row
SELECT
  COALESCE(LOAN_STATUS_GROUP, 'TOTAL')        AS LOAN_STATUS_GROUP,
  COUNT(*)                                    AS LOANS,
  ROUND(SUM(LOAN_AMNT) / 1e9, 3)              AS LOAN_AMNT_BILLIONS,
  ROUND(SUM(NET_CHARGE_OFF_AMNT) / 1e6, 1)    AS NET_CHARGE_OFF_MILLIONS,
  COUNT_IF(ISSUE_DATE IS NULL)                AS NULL_ISSUE_DATE
FROM STAGING.STG_LOANS
GROUP BY ROLLUP (LOAN_STATUS_GROUP)
ORDER BY LOANS DESC;
