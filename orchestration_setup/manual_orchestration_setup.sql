USE WAREHOUSE tasty_bytes_dbt_wh;
USE ROLE DBT_DEV_ROLE;

CREATE OR REPLACE TASK tasty_bytes_dbt_db.raw.dbt_deps_task
	WAREHOUSE=TASTY_BYTES_DBT_WH
	AS EXECUTE DBT PROJECT "TASTY_BYTES_DBT_DB"."RAW"."SAMPLE_DBT_PROJECT" args='deps --target dev' external_access_integrations = (DBT_ACCESS_INTEGRATION);


CREATE OR REPLACE TASK tasty_bytes_dbt_db.raw.dbt_run_task
	WAREHOUSE=TASTY_BYTES_DBT_WH
	AFTER tasty_bytes_dbt_db.raw.dbt_deps_task
	AS EXECUTE DBT PROJECT "TASTY_BYTES_DBT_DB"."RAW"."SAMPLE_DBT_PROJECT" args='run --target dev';

-- Run the tasks once
ALTER TASK tasty_bytes_dbt_db.raw.dbt_run_task RESUME;
-- ALTER TASK tasty_bytes_dbt_db.raw.dbt_test_task RESUME;
EXECUTE TASK tasty_bytes_dbt_db.raw.dbt_deps_task;