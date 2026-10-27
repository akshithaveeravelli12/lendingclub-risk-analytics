-- =====================================================================
-- 07_powerbi_views.sql  |  Extra view for the Power BI state map
-- Power BI pages read: VW_PORTFOLIO_KPIS, VW_RISK_BY_SEGMENT,
-- VW_VINTAGE_CURVES, VW_DELINQUENCY_BUCKETS, VW_RISK_BY_STATE
-- =====================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE LOAN_WH;
USE DATABASE LOAN_RISK;

CREATE OR REPLACE VIEW MARTS.VW_RISK_BY_STATE AS
SELECT
  b.ADDR_STATE                                              AS STATE,
  COUNT(*)                                                  AS LOANS,
  ROUND(SUM(f.FUNDED_AMNT) / 1e6, 1)                        AS FUNDED_MILLIONS,
  ROUND(SUM(IFF(NOT f.IS_RESOLVED, f.OUT_PRNCP, 0)) / 1e6, 1) AS OUTSTANDING_MILLIONS,
  ROUND(100 * COUNT_IF(f.LOAN_STATUS_GROUP = 'CHARGED_OFF')
            / NULLIF(COUNT_IF(f.IS_RESOLVED), 0), 2)        AS CHARGE_OFF_RATE_PCT,
  ROUND(100 * COUNT_IF(f.IS_DELINQUENT)
            / NULLIF(COUNT_IF(NOT f.IS_RESOLVED), 0), 2)    AS DELINQUENCY_RATE_PCT,
  ROUND(SUM(f.NET_CHARGE_OFF_AMNT) / 1e6, 1)                AS NET_CHARGE_OFF_MILLIONS
FROM MARTS.FCT_LOAN f
JOIN MARTS.DIM_BORROWER b ON b.BORROWER_KEY = f.BORROWER_KEY
GROUP BY b.ADDR_STATE;

SELECT *
FROM MARTS.VW_RISK_BY_STATE
ORDER BY FUNDED_MILLIONS DESC;
