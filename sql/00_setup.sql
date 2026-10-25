-- =====================================================================
-- 00_setup.sql  |  Run once in a Snowflake worksheet (role SYSADMIN)
-- Creates: warehouse, database, RAW/STAGING/MARTS/AUDIT schemas,
--          CSV file format, internal stage, audit tables
-- =====================================================================
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS LOAN_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60          -- seconds
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS LOAN_RISK;
USE DATABASE LOAN_RISK;
USE WAREHOUSE LOAN_WH;

CREATE SCHEMA IF NOT EXISTS RAW      COMMENT = 'Landed as-is from source, all VARCHAR + lineage columns';
CREATE SCHEMA IF NOT EXISTS STAGING  COMMENT = 'Typed, cleaned, deduplicated';
CREATE SCHEMA IF NOT EXISTS MARTS    COMMENT = 'Star schema: FCT_LOAN, DIM_BORROWER, DIM_DATE + KPI views';
CREATE SCHEMA IF NOT EXISTS AUDIT    COMMENT = 'Load log, source profile, reconciliation results';

-- ---------------------------------------------------------------------
-- File format: LendingClub CSV has quoted free-text fields (desc, emp_title)
-- that can contain commas and line breaks, plus a few footer/summary rows
-- with fewer columns. Keep the load permissive; RAW checks surface the junk.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT RAW.FF_LC_CSV
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ESCAPE_UNENCLOSED_FIELD = NONE
  NULL_IF = ('', 'NULL', 'null')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMPRESSION = AUTO
  ENCODING = 'UTF8';

CREATE STAGE IF NOT EXISTS RAW.STG_LC
  FILE_FORMAT = RAW.FF_LC_CSV
  COMMENT = 'Internal stage for LendingClub source files';

-- ---------------------------------------------------------------------
-- Audit tables
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AUDIT.SOURCE_PROFILE (
    BATCH_ID      VARCHAR,
    SOURCE_FILE   VARCHAR,
    METRIC_NAME   VARCHAR,        -- e.g. ROW_COUNT, SUM_LOAN_AMNT, NULL_COUNT:loan_status
    METRIC_VALUE  NUMBER(38,4),
    PROFILED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS AUDIT.LOAD_LOG (
    BATCH_ID      VARCHAR,
    SOURCE_FILE   VARCHAR,
    TARGET_TABLE  VARCHAR,
    STATUS        VARCHAR,
    ROWS_PARSED   NUMBER,
    ROWS_LOADED   NUMBER,
    ERRORS_SEEN   NUMBER,
    FIRST_ERROR   VARCHAR,
    LOADED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Filled in Step 2 (source-to-target reconciliation)
CREATE TABLE IF NOT EXISTS AUDIT.RECON_RESULTS (
    BATCH_ID      VARCHAR,
    CHECK_NAME    VARCHAR,
    LAYER_FROM    VARCHAR,
    LAYER_TO      VARCHAR,
    EXPECTED      NUMBER(38,4),
    ACTUAL        NUMBER(38,4),
    VARIANCE      NUMBER(38,4),
    TOLERANCE     NUMBER(38,4),
    STATUS        VARCHAR,        -- PASS / FAIL / WARN
    CHECKED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

SHOW SCHEMAS IN DATABASE LOAN_RISK;
