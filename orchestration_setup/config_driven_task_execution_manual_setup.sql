USE ROLE DBT_DEV_ROLE; 
USE WAREHOUSE TASTY_BYTES_DBT_WH;
USE DATABASE TASTY_BYTES_ANALYTICS_DB;
USE SCHEMA INTEGRATIONS;

CALL process_stage_files('DBT_CONFIG_STAGE');

CALL load_dbt_config('food_truck_project', 'food_truck_project.json');

CALL validate_dbt_config('food_truck_project');

CALL list_all_feeds();

CALL show_feed_task_status('food_truck_project');

CALL preview_dbt_tasks('food_truck_project');

CALL execute_dbt_tasks('food_truck_project');

CALL resume_all_dbt_tasks('food_truck_project');

-- CALL drop_all_dbt_tasks('food_truck_project');
