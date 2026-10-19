-- =====================================================================
-- 01_raw_checks.sql  |  Sanity checks on RAW.LC_LOANS_RAW after load
-- Full source-to-target reconciliation (with PASS/FAIL logging) is Step 2.
-- =====================================================================
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

SET BATCH_ID = (SELECT MAX(_BATCH_ID) FROM RAW.LC_LOANS_RAW);

-- 1. What did COPY report?
SELECT * FROM AUDIT.LOAD_LOG WHERE BATCH_ID = $BATCH_ID ORDER BY LOADED_AT DESC;

-- 2. Row count: pandas (source) vs Snowflake (target)
SELECT
    sp.METRIC_VALUE                         AS SOURCE_ROWS,
    (SELECT COUNT(*) FROM RAW.LC_LOANS_RAW WHERE _BATCH_ID = $BATCH_ID) AS RAW_ROWS,
    RAW_ROWS - SOURCE_ROWS                  AS DIFF
FROM AUDIT.SOURCE_PROFILE sp
WHERE sp.BATCH_ID = $BATCH_ID AND sp.METRIC_NAME = 'ROW_COUNT';

-- 3. Loan amount totals: source vs raw (cast here only; RAW stays VARCHAR)
SELECT
    MAX(IFF(sp.METRIC_NAME = 'SUM_LOAN_AMNT',   sp.METRIC_VALUE, NULL)) AS SRC_LOAN_AMNT,
    (SELECT SUM(TRY_TO_NUMBER(LOAN_AMNT, 38, 2)) FROM RAW.LC_LOANS_RAW WHERE _BATCH_ID = $BATCH_ID) AS RAW_LOAN_AMNT,
    MAX(IFF(sp.METRIC_NAME = 'SUM_FUNDED_AMNT', sp.METRIC_VALUE, NULL)) AS SRC_FUNDED_AMNT,
    (SELECT SUM(TRY_TO_NUMBER(FUNDED_AMNT, 38, 2)) FROM RAW.LC_LOANS_RAW WHERE _BATCH_ID = $BATCH_ID) AS RAW_FUNDED_AMNT
FROM AUDIT.SOURCE_PROFILE sp
WHERE sp.BATCH_ID = $BATCH_ID;

-- 4. Junk rows: non-numeric ids (LendingClub summary/footer lines, blank rows)
SELECT ID, LOAN_AMNT, LOAN_STATUS, _SOURCE_ROW_NUMBER
FROM RAW.LC_LOANS_RAW
WHERE _BATCH_ID = $BATCH_ID AND TRY_TO_NUMBER(ID) IS NULL
LIMIT 50;

-- 5. Duplicate loan ids
SELECT ID, COUNT(*) AS N
FROM RAW.LC_LOANS_RAW
WHERE _BATCH_ID = $BATCH_ID AND TRY_TO_NUMBER(ID) IS NOT NULL
GROUP BY ID HAVING COUNT(*) > 1
ORDER BY N DESC
LIMIT 20;

-- 6. Nulls on columns the marts depend on
SELECT
    COUNT(*)                                   AS TOTAL_ROWS,
    COUNT_IF(LOAN_AMNT   IS NULL)              AS NULL_LOAN_AMNT,
    COUNT_IF(ISSUE_D     IS NULL)              AS NULL_ISSUE_D,
    COUNT_IF(LOAN_STATUS IS NULL)              AS NULL_LOAN_STATUS,
    COUNT_IF(GRADE       IS NULL)              AS NULL_GRADE,
    COUNT_IF(INT_RATE    IS NULL)              AS NULL_INT_RATE,
    COUNT_IF(ADDR_STATE  IS NULL)              AS NULL_ADDR_STATE
FROM RAW.LC_LOANS_RAW
WHERE _BATCH_ID = $BATCH_ID;

-- 7. Type-ability: values present but won't cast (what STAGING will have to handle)
SELECT
    COUNT_IF(LOAN_AMNT IS NOT NULL AND TRY_TO_NUMBER(LOAN_AMNT, 38, 2) IS NULL)          AS BAD_LOAN_AMNT,
    COUNT_IF(INT_RATE  IS NOT NULL AND TRY_TO_NUMBER(REPLACE(INT_RATE, '%', ''), 10, 4) IS NULL) AS BAD_INT_RATE,
    COUNT_IF(ISSUE_D   IS NOT NULL AND TRY_TO_DATE(ISSUE_D, 'MON-YYYY') IS NULL)          AS BAD_ISSUE_D
FROM RAW.LC_LOANS_RAW
WHERE _BATCH_ID = $BATCH_ID;

-- 8. Date range and volume by origination year
SELECT
    YEAR(TRY_TO_DATE(ISSUE_D, 'MON-YYYY'))           AS ISSUE_YEAR,
    COUNT(*)                                          AS LOANS,
    ROUND(SUM(TRY_TO_NUMBER(LOAN_AMNT, 38, 2)) / 1e6, 1) AS LOAN_AMNT_MM
FROM RAW.LC_LOANS_RAW
WHERE _BATCH_ID = $BATCH_ID AND TRY_TO_NUMBER(ID) IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- 9. Loan status distribution (drives default / delinquency definitions in Step 3)
SELECT LOAN_STATUS, COUNT(*) AS LOANS, ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 2) AS PCT
FROM RAW.LC_LOANS_RAW
WHERE _BATCH_ID = $BATCH_ID
GROUP BY 1 ORDER BY 2 DESC;
