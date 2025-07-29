CALL load_dbt_config('food_truck_project', 'food_truck_project.json');

CALL validate_dbt_config('food_truck_project');

CALL preview_dbt_tasks('food_truck_project');

CALL execute_dbt_tasks('food_truck_project');

CALL resume_all_dbt_tasks('food_truck_project');

-- CALL drop_all_dbt_tasks('food_truck_project');
