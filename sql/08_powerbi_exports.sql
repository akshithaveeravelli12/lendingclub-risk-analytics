-- =====================================================================
-- 08_powerbi_exports.sql  |  Extracts loaded into Power BI
-- Run each query on its own and download the result as CSV into
-- powerbi_data/ with the file name shown.
-- =====================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

-- pbi_portfolio_kpis.csv
SELECT * FROM LOAN_RISK.MARTS.VW_PORTFOLIO_KPIS;

-- pbi_risk_by_segment.csv
SELECT * FROM LOAN_RISK.MARTS.VW_RISK_BY_SEGMENT;

-- pbi_vintage_curves.csv
SELECT * FROM LOAN_RISK.MARTS.VW_VINTAGE_CURVES ORDER BY VINTAGE_YEAR, MOB;

-- pbi_delinquency_buckets.csv
SELECT * FROM LOAN_RISK.MARTS.VW_DELINQUENCY_BUCKETS ORDER BY VINTAGE_YEAR, GRADE, BUCKET_ORDER;

-- pbi_risk_by_state.csv
SELECT * FROM LOAN_RISK.MARTS.VW_RISK_BY_STATE ORDER BY STATE;
