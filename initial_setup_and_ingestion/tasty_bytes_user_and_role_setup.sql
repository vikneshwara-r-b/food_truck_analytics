-- DBT project service user and service role setup

USE ROLE SECURITYADMIN;

CREATE OR REPLACE ROLE DBT_DEV_ROLE COMMENT='DBT_DEV_ROLE';

USE ROLE ACCOUNTADMIN;

GRANT CREATE DATABASE ON ACCOUNT TO ROLE DBT_DEV_ROLE;

GRANT ROLE DBT_DEV_ROLE TO ROLE SYSADMIN;

-- Replace <Password_for_User> with required password
CREATE OR REPLACE USER DBT_USER PASSWORD='<Password_for_User>'
	DEFAULT_ROLE=DBT_DEV_ROLE
	DEFAULT_WAREHOUSE=tasty_bytes_dbt_wh
	COMMENT='dbt User';

ALTER USER DBT_USER SET DEFAULT_SECONDARY_ROLES = ('ALL');

GRANT ROLE DBT_DEV_ROLE TO USER DBT_USER;

-- Create warehouse

USE ROLE SYSADMIN;

CREATE OR REPLACE WAREHOUSE tasty_bytes_dbt_wh
    WAREHOUSE_SIZE = 'small'
    WAREHOUSE_TYPE = 'standard'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'warehouse for tasty bytes dbt demo';

GRANT ALL ON WAREHOUSE tasty_bytes_dbt_wh TO ROLE DBT_DEV_ROLE;

-- Create database and all schema

USE ROLE DBT_DEV_ROLE;
USE WAREHOUSE tasty_bytes_dbt_wh;

CREATE DATABASE IF NOT EXISTS tasty_bytes_dbt_db;
CREATE OR REPLACE SCHEMA tasty_bytes_dbt_db.raw;
CREATE OR REPLACE SCHEMA tasty_bytes_dbt_db.dev;
CREATE OR REPLACE SCHEMA tasty_bytes_dbt_db.prod;


USE ROLE ACCOUNTADMIN;
ALTER SCHEMA tasty_bytes_dbt_db.dev SET LOG_LEVEL = 'INFO';
ALTER SCHEMA tasty_bytes_dbt_db.dev SET TRACE_LEVEL = 'ALWAYS';
ALTER SCHEMA tasty_bytes_dbt_db.dev SET METRIC_LEVEL = 'ALL';

ALTER SCHEMA tasty_bytes_dbt_db.prod SET LOG_LEVEL = 'INFO';
ALTER SCHEMA tasty_bytes_dbt_db.prod SET TRACE_LEVEL = 'ALWAYS';
ALTER SCHEMA tasty_bytes_dbt_db.prod SET METRIC_LEVEL = 'ALL';

-- Setup github integration to pull git repo into Snowflake workspace

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE API INTEGRATION git_integration
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/')
  ENABLED = TRUE;

-- Grant usage on the integration to your custom role
GRANT USAGE ON INTEGRATION git_integration TO ROLE DBT_DEV_ROLE;

-- Setup dependency configuration in Snowflake for accessing DBT packages

CREATE OR REPLACE NETWORK RULE tasty_bytes_dbt_db.public.dbt_network_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com');

-- Grant usage on the integration to your custom role
GRANT USAGE ON NETWORK RULE tasty_bytes_dbt_db.public.dbt_network_rule TO ROLE DBT_DEV_ROLE;

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION dbt_access_integration
  ALLOWED_NETWORK_RULES = (tasty_bytes_dbt_db.public.dbt_network_rule)
  ENABLED = true;

-- Grant usage on the integration to your custom role
GRANT USAGE ON INTEGRATION dbt_access_integration TO ROLE DBT_DEV_ROLE;

-- Setup Task-related privileges
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DBT_DEV_ROLE;
GRANT CREATE TASK ON SCHEMA tasty_bytes_dbt_db.raw TO ROLE DBT_DEV_ROLE;

