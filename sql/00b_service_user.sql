-- =====================================================================
-- 00b_service_user.sql  |  Pipeline service user with RSA key-pair auth
-- Generate keys first (Terminal):
--   mkdir -p ~/.snowflake
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.snowflake/rsa_key.p8 -nocrypt
--   openssl rsa -in ~/.snowflake/rsa_key.p8 -pubout -out ~/.snowflake/rsa_key.pub
--   chmod 600 ~/.snowflake/rsa_key.p8
--   grep -v "PUBLIC KEY" ~/.snowflake/rsa_key.pub | tr -d '\n'; echo   -- copy this into the SQL below
-- =====================================================================
USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS LOAN_PIPELINE_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = SYSADMIN
  DEFAULT_WAREHOUSE = LOAN_WH
  RSA_PUBLIC_KEY = '<paste public key body here>';

GRANT ROLE SYSADMIN TO USER LOAN_PIPELINE_SVC;

DESC USER LOAN_PIPELINE_SVC;
