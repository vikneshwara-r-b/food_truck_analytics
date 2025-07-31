-- =====================================================================
-- Dynamic dbt Task Generator - Snowflake SQL Implementation (Updated)
-- =====================================================================
-- This script reads JSON configuration from a Snowflake stage and 
-- generates CREATE TASK statements dynamically with feed-based organization
-- and task enable/disable functionality
-- =====================================================================

-- =====================================================================
-- STEP 1: CREATE INFRASTRUCTURE
-- =====================================================================

USE ROLE DBT_DEV_ROLE; 
USE WAREHOUSE TASTY_BYTES_DBT_WH;
USE DATABASE TASTY_BYTES_ANALYTICS_DB;
USE SCHEMA INTEGRATIONS;


-- Create a stage for storing JSON configuration files
CREATE STAGE IF NOT EXISTS dbt_config_stage DIRECTORY = ( ENABLE = TRUE );

-- Create a table to store the parsed JSON configuration
CREATE OR REPLACE TABLE dbt_task_config (
    feed_name STRING,
    config_data VARIANT,
    loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_dbt_task_config PRIMARY KEY (feed_name)
);

-- =====================================================================
-- STEP 2: CONFIGURATION MANAGEMENT PROCEDURES
-- =====================================================================

-- Procedure to load JSON configuration from stage with feed association
CREATE OR REPLACE PROCEDURE load_dbt_config(feed_name_param STRING, config_file_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    copy_sql STRING;
    temp_table_name STRING;
BEGIN
    -- First, delete existing config for this feed if it exists
    DELETE FROM dbt_task_config WHERE feed_name = :feed_name_param;
    
    -- Create a unique temporary table name
    temp_table_name := 'temp_config_' || REGEXP_REPLACE(CURRENT_TIMESTAMP()::STRING, '[ :\.-]', '_');
    
    -- First, copy the JSON data into a temporary table
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_table_name || ' (json_data VARIANT)';
    EXECUTE IMMEDIATE :copy_sql;
    
    copy_sql := 'COPY INTO ' || temp_table_name || '(json_data) ' ||
                'FROM @dbt_config_stage/' || config_file_name || ' ' ||
                'FILE_FORMAT = (TYPE = ''JSON'')';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Now insert into the main table with the feed name
    copy_sql := 'INSERT INTO dbt_task_config (feed_name, config_data) ' ||
                'SELECT ''' || feed_name_param || ''', json_data FROM ' || temp_table_name;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Clean up temporary table
    copy_sql := 'DROP TABLE IF EXISTS ' || temp_table_name;
    EXECUTE IMMEDIATE :copy_sql;
    
    RETURN 'Configuration loaded successfully for feed: ' || feed_name_param;
EXCEPTION
    WHEN OTHER THEN
        RETURN 'Error loading configuration: ' || SQLERRM;
END;
$$;

-- Procedure to validate JSON configuration for a specific feed
CREATE OR REPLACE PROCEDURE validate_dbt_config(feed_name_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    config_data VARIANT;
    project_config VARIANT;
    tasks_array VARIANT;
    validation_result STRING := 'Configuration is valid for feed: ' || feed_name_param;
    i INTEGER;
    task_name STRING;
    dbt_command STRING;
BEGIN
    -- Get the configuration for the specified feed
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists
    IF (config_data IS NULL) THEN
        RETURN 'Error: No configuration found for feed: ' || feed_name_param || '. Please load a JSON file first.';
    END IF;
    
    -- Validate project_config section
    project_config := config_data:project_config;
    IF (project_config IS NULL) THEN
        RETURN 'Error: Missing project_config section for feed: ' || feed_name_param;
    END IF;
    
    -- Validate required project fields
    IF (project_config:database IS NULL) THEN
        RETURN 'Error: Missing required field: project_config.database for feed: ' || feed_name_param;
    END IF;
    
    IF (project_config:schema IS NULL) THEN
        RETURN 'Error: Missing required field: project_config.schema for feed: ' || feed_name_param;
    END IF;
    
    IF (project_config:project_name IS NULL) THEN
        RETURN 'Error: Missing required field: project_config.project_name for feed: ' || feed_name_param;
    END IF;
    
    -- Validate tasks array
    tasks_array := config_data:tasks;
    IF (tasks_array IS NULL OR ARRAY_SIZE(tasks_array) = 0) THEN
        RETURN 'Error: Missing or empty tasks array for feed: ' || feed_name_param;
    END IF;
    
    -- Validate each task
    FOR i IN 0 TO (ARRAY_SIZE(tasks_array) - 1) DO
        task_name := tasks_array[i]:name::STRING;
        dbt_command := tasks_array[i]:dbt_command::STRING;
        
        IF (task_name IS NULL) THEN
            RETURN 'Error: Task ' || (i + 1)::STRING || ' is missing name field for feed: ' || feed_name_param;
        END IF;
        
        IF (dbt_command IS NULL) THEN
            RETURN 'Error: Task ' || (i + 1)::STRING || ' is missing dbt_command field for feed: ' || feed_name_param;
        END IF;
    END FOR;
    
    RETURN validation_result;
END;
$$;

-- Procedure to load stage files into dbt_task_config table
CREATE OR REPLACE PROCEDURE process_stage_files(stage_name VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
try {
    var listStmt = snowflake.createStatement({
        sqlText: "LIST @" + STAGE_NAME
    });
    var listResult = listStmt.execute();

    var processedFiles = [];
    var errorFiles = [];
    
    while (listResult.next()) {
        var fileName = listResult.getColumnValue("name");
        var baseFileName = fileName.split('/').pop();
        var idx = baseFileName.lastIndexOf(".");
        var fileNameNoExt = idx > 0 ? baseFileName.slice(0, idx) : baseFileName;

        try {
            snowflake.createStatement({
                sqlText: "CALL load_dbt_config(?, ?)",
                binds: [fileNameNoExt, baseFileName]
            }).execute();
            processedFiles.push("load_dbt_config called for: " + baseFileName + " / " + fileNameNoExt);
        } catch (err) {
            errorFiles.push(baseFileName + ": " + err.message);
        }
    }

    return JSON.stringify({
        "processed_files": processedFiles,
        "error_files": errorFiles,
        "total_processed": processedFiles.length,
        "total_errors": errorFiles.length
    });

} catch (err) {
    return "Error: " + err.message;
}
$$;

-- =====================================================================
-- STEP 3: TASK GENERATION PROCEDURES
-- =====================================================================

-- Procedure to generate task SQL dynamically (preview only)
CREATE OR REPLACE PROCEDURE generate_dbt_tasks(feed_name_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    config_data VARIANT;
    project_config VARIANT;
    tasks_array VARIANT;
    task_sql STRING := '';
    final_sql STRING := '';
    task_name STRING;
    warehouse STRING;
    schedule STRING;
    dbt_command STRING;
    target STRING;
    depends_on VARIANT;
    external_access_integrations VARIANT;
    enabled BOOLEAN;
    database_name STRING;
    schema_name STRING;
    project_name STRING;
    default_warehouse STRING;
    default_target STRING;
    task_full_name STRING;
    project_full_name STRING;
    dependency_clause STRING;
    external_access_clause STRING;
    i INTEGER;
    j INTEGER;
    dep_name STRING;
    integration_name STRING;
    header_comment STRING;
    execution_commands STRING := '';
    enabled_tasks INTEGER := 0;
    disabled_tasks INTEGER := 0;
BEGIN
    -- Get the configuration for the specified feed
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No configuration found for feed: ' || feed_name_param;
    END IF;
    
    -- Extract project configuration
    project_config := config_data:project_config;
    database_name := project_config:database::STRING;
    schema_name := project_config:schema::STRING;
    project_name := project_config:project_name::STRING;
    default_warehouse := project_config:default_warehouse::STRING;
    default_target := project_config:default_target::STRING;
    
    -- Generate header comment
    header_comment := '-- Generated dbt Tasks for ' || project_name || ' (Feed: ' || feed_name_param || ')\n' ||
                     '-- Database: ' || database_name || '\n' ||
                     '-- Schema: ' || schema_name || '\n' ||
                     '-- Generated on: ' || CURRENT_TIMESTAMP()::STRING || '\n\n';
    
    final_sql := header_comment;
    
    -- Extract tasks array
    tasks_array := config_data:tasks;
    
    -- Loop through each task
    FOR i IN 0 TO (ARRAY_SIZE(tasks_array) - 1) DO
        task_name := tasks_array[i]:name::STRING;
        enabled := COALESCE(tasks_array[i]:enabled::BOOLEAN, TRUE); -- Default to enabled if not specified
        
        -- Check if task is enabled
        IF (enabled = TRUE) THEN
            warehouse := COALESCE(tasks_array[i]:warehouse::STRING, default_warehouse);
            schedule := tasks_array[i]:schedule::STRING;
            dbt_command := tasks_array[i]:dbt_command::STRING;
            target := COALESCE(tasks_array[i]:target::STRING, default_target);
            depends_on := tasks_array[i]:depends_on;
            external_access_integrations := tasks_array[i]:external_access_integrations;
            
            -- Build task full name with feed prefix
            task_full_name := database_name || '.' || schema_name || '.' || feed_name_param || '_' || task_name;
            project_full_name := '"' || database_name || '"."' || schema_name || '"."' || project_name || '"';
            
            -- Start building task SQL
            task_sql := 'CREATE OR REPLACE TASK ' || task_full_name;
            
            -- Add warehouse
            IF (warehouse IS NOT NULL) THEN
                task_sql := task_sql || '\n\tWAREHOUSE=' || warehouse;
            END IF;
            
            -- Add schedule or dependencies (only consider enabled dependencies)
            IF (schedule IS NOT NULL) THEN
                task_sql := task_sql || '\n\tSCHEDULE=''' || schedule || '''';
            ELSEIF (depends_on IS NOT NULL AND ARRAY_SIZE(depends_on) > 0) THEN
                dependency_clause := '\n\tAFTER ';
                FOR j IN 0 TO (ARRAY_SIZE(depends_on) - 1) DO
                    dep_name := depends_on[j]::STRING;
                    -- Only add dependency if the dependent task is also enabled
                    IF (j > 0) THEN
                        dependency_clause := dependency_clause || ', ';
                    END IF;
                    -- Add feed prefix to dependency names
                    dependency_clause := dependency_clause || database_name || '.' || schema_name || '.' || feed_name_param || '_' || dep_name;
                END FOR;
                task_sql := task_sql || dependency_clause;
            END IF;
            
            -- Add main command
            task_sql := task_sql || '\n\tAS EXECUTE DBT PROJECT ' || project_full_name || 
                       ' args=''' || dbt_command || ' --target ' || target || '''';
            
            -- Add external access integrations
            IF (external_access_integrations IS NOT NULL AND ARRAY_SIZE(external_access_integrations) > 0) THEN
                external_access_clause := ' external_access_integrations = (';
                FOR j IN 0 TO (ARRAY_SIZE(external_access_integrations) - 1) DO
                    integration_name := external_access_integrations[j]::STRING;
                    IF (j > 0) THEN
                        external_access_clause := external_access_clause || ', ';
                    END IF;
                    external_access_clause := external_access_clause || integration_name;
                END FOR;
                external_access_clause := external_access_clause || ')';
                task_sql := task_sql || external_access_clause;
            END IF;
            
            task_sql := task_sql || ';\n\n';
            final_sql := final_sql || task_sql;
            
            -- Add to execution commands
            execution_commands := execution_commands || '-- ALTER TASK ' || task_full_name || ' RESUME;\n';
            enabled_tasks := enabled_tasks + 1;
        ELSE
            -- Task is disabled, add comment
            final_sql := final_sql || '-- DISABLED TASK: ' || feed_name_param || '_' || task_name || ' (enabled=false)\n\n';
            disabled_tasks := disabled_tasks + 1;
        END IF;
    END FOR;
    
    -- Add execution commands section and summary
    final_sql := final_sql || '-- Task execution commands:\n' || execution_commands;
    final_sql := final_sql || '-- Summary: ' || enabled_tasks::STRING || ' enabled tasks, ' || disabled_tasks::STRING || ' disabled tasks\n';
    
    RETURN final_sql;
END;
$$;

-- Procedure to preview the generated SQL without executing
CREATE OR REPLACE PROCEDURE preview_dbt_tasks(feed_name_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    generated_sql STRING;
BEGIN
    CALL generate_dbt_tasks(:feed_name_param) INTO :generated_sql;
    RETURN generated_sql;
END;
$$;

-- =====================================================================
-- STEP 4: TASK EXECUTION PROCEDURES
-- =====================================================================

-- Procedure to execute the generated SQL (create tasks)
CREATE OR REPLACE PROCEDURE create_dbt_tasks(feed_name_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    config_data VARIANT;
    project_config VARIANT;
    tasks_array VARIANT;
    task_sql STRING := '';
    task_name STRING;
    warehouse STRING;
    schedule STRING;
    dbt_command STRING;
    target STRING;
    depends_on VARIANT;
    external_access_integrations VARIANT;
    enabled BOOLEAN;
    database_name STRING;
    schema_name STRING;
    project_name STRING;
    default_warehouse STRING;
    default_target STRING;
    task_full_name STRING;
    project_full_name STRING;
    dependency_clause STRING;
    external_access_clause STRING;
    i INTEGER;
    j INTEGER;
    k INTEGER;
    dep_name STRING;
    integration_name STRING;
    tasks_created INTEGER := 0;
    tasks_skipped INTEGER := 0;
    enabled_dependencies ARRAY;
    dependency_enabled BOOLEAN;
    dependency_task_name STRING;
BEGIN
    -- Get the configuration for the specified feed
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No configuration found for feed: ' || feed_name_param;
    END IF;
    
    -- Extract project configuration
    project_config := config_data:project_config;
    database_name := project_config:database::STRING;
    schema_name := project_config:schema::STRING;
    project_name := project_config:project_name::STRING;
    default_warehouse := project_config:default_warehouse::STRING;
    default_target := project_config:default_target::STRING;
    
    -- Extract tasks array
    tasks_array := config_data:tasks;
    
    -- Loop through each task and execute individually
    FOR i IN 0 TO (ARRAY_SIZE(tasks_array) - 1) DO
        task_name := tasks_array[i]:name::STRING;
        enabled := COALESCE(tasks_array[i]:enabled::BOOLEAN, TRUE); -- Default to enabled if not specified
        
        -- Only create task if enabled
        IF (enabled = TRUE) THEN
            warehouse := COALESCE(tasks_array[i]:warehouse::STRING, default_warehouse);
            schedule := tasks_array[i]:schedule::STRING;
            dbt_command := tasks_array[i]:dbt_command::STRING;
            target := COALESCE(tasks_array[i]:target::STRING, default_target);
            depends_on := tasks_array[i]:depends_on;
            external_access_integrations := tasks_array[i]:external_access_integrations;
            
            -- Build task full name with feed prefix
            task_full_name := database_name || '.' || schema_name || '.' || feed_name_param || '_' || task_name;
            project_full_name := '"' || database_name || '"."' || schema_name || '"."' || project_name || '"';
            
            -- Start building task SQL
            task_sql := 'CREATE OR REPLACE TASK ' || task_full_name;
            
            -- Add warehouse
            IF (warehouse IS NOT NULL) THEN
                task_sql := task_sql || '\n\tWAREHOUSE=' || warehouse;
            END IF;
            
            -- Add schedule or dependencies (only for enabled dependencies)
            IF (schedule IS NOT NULL) THEN
                task_sql := task_sql || '\n\tSCHEDULE=''' || schedule || '''';
            ELSEIF (depends_on IS NOT NULL AND ARRAY_SIZE(depends_on) > 0) THEN
                -- Filter dependencies to only include enabled tasks
                enabled_dependencies := ARRAY_CONSTRUCT();
                
                FOR j IN 0 TO (ARRAY_SIZE(depends_on) - 1) DO
                    dep_name := depends_on[j]::STRING;
                    dependency_enabled := FALSE;
                    
                    -- Check if this dependency is enabled in the configuration
                    FOR k IN 0 TO (ARRAY_SIZE(tasks_array) - 1) DO
                        dependency_task_name := tasks_array[k]:name::STRING;
                        IF (dependency_task_name = dep_name) THEN
                            dependency_enabled := COALESCE(tasks_array[k]:enabled::BOOLEAN, TRUE);
                            EXIT;
                        END IF;
                    END FOR;
                    
                    -- Only add to dependencies if the dependent task is enabled
                    IF (dependency_enabled = TRUE) THEN
                        enabled_dependencies := ARRAY_APPEND(enabled_dependencies, dep_name);
                    END IF;
                END FOR;
                
                -- Only add AFTER clause if there are enabled dependencies
                IF (ARRAY_SIZE(enabled_dependencies) > 0) THEN
                    dependency_clause := '\n\tAFTER ';
                    FOR j IN 0 TO (ARRAY_SIZE(enabled_dependencies) - 1) DO
                        dep_name := enabled_dependencies[j]::STRING;
                        IF (j > 0) THEN
                            dependency_clause := dependency_clause || ', ';
                        END IF;
                        -- Add feed prefix to dependency names
                        dependency_clause := dependency_clause || database_name || '.' || schema_name || '.' || feed_name_param || '_' || dep_name;
                    END FOR;
                    task_sql := task_sql || dependency_clause;
                END IF;
            END IF;
            
            -- Add main command
            task_sql := task_sql || '\n\tAS EXECUTE DBT PROJECT ' || project_full_name || 
                       ' args=''' || dbt_command || ' --target ' || target || '''';
            
            -- Add external access integrations
            IF (external_access_integrations IS NOT NULL AND ARRAY_SIZE(external_access_integrations) > 0) THEN
                external_access_clause := ' external_access_integrations = (';
                FOR j IN 0 TO (ARRAY_SIZE(external_access_integrations) - 1) DO
                    integration_name := external_access_integrations[j]::STRING;
                    IF (j > 0) THEN
                        external_access_clause := external_access_clause || ', ';
                    END IF;
                    external_access_clause := external_access_clause || integration_name;
                END FOR;
                external_access_clause := external_access_clause || ')';
                task_sql := task_sql || external_access_clause;
            END IF;
            
            -- Execute this individual task creation
            EXECUTE IMMEDIATE :task_sql;
            tasks_created := tasks_created + 1;
        ELSE
            -- Task is disabled, skip it
            tasks_skipped := tasks_skipped + 1;
        END IF;
    END FOR;
    
    RETURN 'Successfully created ' || tasks_created::STRING || ' enabled dbt tasks for feed: ' || feed_name_param || 
           ' (Skipped ' || tasks_skipped::STRING || ' disabled tasks)';
EXCEPTION
    WHEN OTHER THEN
        RETURN 'Error executing tasks for feed ' || feed_name_param || ': ' || SQLERRM || ' (Task: ' || COALESCE(task_name, 'unknown') || ')';
END;
$$;

-- =====================================================================
-- STEP 5: TASK MANAGEMENT PROCEDURES
-- =====================================================================

-- Procedure to resume all enabled dbt tasks for a specific feed (excluding root task)
CREATE OR REPLACE PROCEDURE resume_all_dbt_tasks(feed_name_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    config_data VARIANT;
    project_config VARIANT;
    tasks_array VARIANT;
    database_name STRING;
    schema_name STRING;
    task_name STRING;
    task_full_name STRING;
    resume_sql STRING := '';
    enabled BOOLEAN;
    schedule STRING;
    depends_on VARIANT;
    is_root_task BOOLEAN;
    i INTEGER;
    tasks_resumed INTEGER := 0;
    tasks_skipped INTEGER := 0;
    root_tasks_skipped INTEGER := 0;
BEGIN
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No configuration found for feed: ' || feed_name_param;
    END IF;
    
    project_config := config_data:project_config;
    database_name := project_config:database::STRING;
    schema_name := project_config:schema::STRING;
    tasks_array := config_data:tasks;
    
    FOR i IN 0 TO (ARRAY_SIZE(tasks_array) - 1) DO
        task_name := tasks_array[i]:name::STRING;
        enabled := COALESCE(tasks_array[i]:enabled::BOOLEAN, TRUE); -- Default to enabled if not specified
        schedule := tasks_array[i]:schedule::STRING;
        depends_on := tasks_array[i]:depends_on;
        
        -- Determine if this is a root task (has schedule OR has no dependencies)
        is_root_task := FALSE;
        IF (schedule IS NOT NULL) THEN
            is_root_task := TRUE;
        ELSEIF (depends_on IS NULL OR ARRAY_SIZE(depends_on) = 0) THEN
            is_root_task := TRUE;
        END IF;
        
        -- Only resume enabled tasks that are NOT root tasks
        IF (enabled = TRUE) THEN
            IF (is_root_task = FALSE) THEN
                task_full_name := database_name || '.' || schema_name || '.' || feed_name_param || '_' || task_name;
                resume_sql := 'ALTER TASK ' || task_full_name || ' RESUME;';
                EXECUTE IMMEDIATE :resume_sql;
                tasks_resumed := tasks_resumed + 1;
            ELSE
                -- Skip root task
                root_tasks_skipped := root_tasks_skipped + 1;
            END IF;
        ELSE
            tasks_skipped := tasks_skipped + 1;
        END IF;
    END FOR;
    
    RETURN 'Successfully resumed ' || tasks_resumed::STRING || ' enabled child tasks for feed: ' || feed_name_param ||
           ' (Skipped ' || tasks_skipped::STRING || ' disabled tasks, ' || root_tasks_skipped::STRING || ' root tasks)';
END;
$$;

-- Procedure to drop all generated tasks for a specific feed
CREATE OR REPLACE PROCEDURE drop_all_dbt_tasks(feed_name_param STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    config_data VARIANT;
    project_config VARIANT;
    tasks_array VARIANT;
    database_name STRING;
    schema_name STRING;
    task_name STRING;
    task_full_name STRING;
    drop_sql STRING := '';
    enabled BOOLEAN;
    i INTEGER;
    tasks_dropped INTEGER := 0;
    tasks_skipped INTEGER := 0;
BEGIN
    -- Get the configuration for the specified feed
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No configuration found for feed: ' || feed_name_param;
    END IF;
    
    -- Extract project configuration
    project_config := config_data:project_config;
    database_name := project_config:database::STRING;
    schema_name := project_config:schema::STRING;
    tasks_array := config_data:tasks;
    
    -- Generate DROP statements for each enabled task with feed prefix
    FOR i IN 0 TO (ARRAY_SIZE(tasks_array) - 1) DO
        task_name := tasks_array[i]:name::STRING;
        enabled := COALESCE(tasks_array[i]:enabled::BOOLEAN, TRUE); -- Default to enabled if not specified
        
        -- Only attempt to drop if task was enabled (and therefore created)
        IF (enabled = TRUE) THEN
            task_full_name := database_name || '.' || schema_name || '.' || feed_name_param || '_' || task_name;
            drop_sql := 'DROP TASK IF EXISTS ' || task_full_name || ';';
            EXECUTE IMMEDIATE :drop_sql;
            tasks_dropped := tasks_dropped + 1;
        ELSE
            tasks_skipped := tasks_skipped + 1;
        END IF;
    END FOR;
    
    RETURN 'Successfully dropped ' || tasks_dropped::STRING || ' enabled dbt tasks for feed: ' || feed_name_param ||
           ' (Skipped ' || tasks_skipped::STRING || ' disabled tasks)';
END;
$$;

-- =====================================================================
-- STEP 6: MONITORING AND REPORTING PROCEDURES
-- =====================================================================

-- Procedure to list all feeds with task status summary
CREATE OR REPLACE PROCEDURE list_all_feeds()
RETURNS TABLE (feed_name STRING, loaded_at TIMESTAMP_LTZ, total_tasks INTEGER, enabled_tasks INTEGER, disabled_tasks INTEGER)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
WITH flattened_tasks AS (
    SELECT 
        dtc.feed_name,
        dtc.loaded_at,
        dtc.config_data:tasks as tasks_array,
        t.value as task_config,
        COALESCE(t.value:enabled::BOOLEAN, TRUE) as is_enabled
    FROM dbt_task_config dtc,
    TABLE(FLATTEN(dtc.config_data:tasks)) t
)
SELECT 
    feed_name,
    loaded_at,
    ARRAY_SIZE(tasks_array) as total_tasks,
    SUM(CASE WHEN is_enabled = TRUE THEN 1 ELSE 0 END) as enabled_tasks,
    SUM(CASE WHEN is_enabled = FALSE THEN 1 ELSE 0 END) as disabled_tasks
FROM flattened_tasks
GROUP BY feed_name, loaded_at, tasks_array
ORDER BY loaded_at DESC
    );
    RETURN TABLE(res);
END;
$$;


-- Procedure to show detailed task status for a specific feed
CREATE OR REPLACE PROCEDURE show_feed_task_status(feed_name_param STRING)
RETURNS TABLE (task_name STRING, enabled BOOLEAN, dbt_command STRING, schedule STRING, depends_on VARIANT)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
        SELECT 
            t.value:name::STRING as task_name,
            COALESCE(t.value:enabled::BOOLEAN, TRUE) as enabled,
            t.value:dbt_command::STRING as dbt_command,
            t.value:schedule::STRING as schedule,
            t.value:depends_on::VARIANT as depends_on
        FROM dbt_task_config dtc,
             TABLE(FLATTEN(dtc.config_data:tasks)) t
        WHERE dtc.feed_name = :feed_name_param
        ORDER BY t.index
    );
    RETURN TABLE(res);
END;
$$;

-- =====================================================================
-- USAGE EXAMPLES
-- =====================================================================

-- 1. Upload your JSON configuration file to the stage
-- PUT file:///path/to/your/config.json @dbt_config_stage;

-- 2. Load the configuration into the table with feed name
-- CALL load_dbt_config('my_feed_name', 'config.json');

-- 3. Validate the configuration for a specific feed
-- CALL validate_dbt_config('my_feed_name');

-- 4. Preview the generated SQL without executing for a specific feed
-- CALL preview_dbt_tasks('my_feed_name');

-- 5. Execute the task generation for a specific feed
-- CALL create_dbt_tasks('my_feed_name');

-- 6. Check created tasks
-- SHOW TASKS LIKE '%my_feed_name%';

-- 7. Resume tasks for a specific feed (if needed)
-- CALL resume_all_dbt_tasks('my_feed_name');

-- 8. Drop all tasks for a specific feed (if needed)
-- CALL drop_all_dbt_tasks('my_feed_name');

-- 9. List all feed configurations with task counts
-- CALL list_all_feeds();

-- 10. Show task status for a specific feed
-- CALL show_feed_task_status('my_feed_name');

-- 11. Enable/disable specific tasks by updating JSON and reloading
-- Update your JSON file to change "enabled": true/false for specific tasks
-- Then reload: CALL load_dbt_config('my_feed_name', 'updated_config.json');

-- 12. To load all JSON files from DBT_CONFIG_STAGE into dbt_task_config table
-- CALL process_stage_files('DBT_CONFIG_STAGE');

-- =====================================================================
-- SAMPLE JSON CONFIGURATION FILE (config.json)
-- =====================================================================
/*
{
  "project_config": {
    "database": "TASTY_BYTES_DBT_DB",
    "schema": "RAW",
    "project_name": "DBT_PROJECT",
    "default_warehouse": "TASTY_BYTES_DBT_WH",
    "default_target": "dev"
  },
  "tasks": [
    {
      "name": "dbt_deps_task",
      "enabled": true,
      "warehouse": "TASTY_BYTES_DBT_WH",
      "schedule": "60 MINUTES",
      "dbt_command": "deps",
      "target": "dev",
      "depends_on": [],
      "external_access_integrations": ["DBT_ACCESS_INTEGRATION"]
    },
    {
      "name": "dbt_run_task",
      "enabled": true,
      "warehouse": "TASTY_BYTES_DBT_WH",
      "dbt_command": "run",
      "depends_on": ["dbt_deps_task"],
      "external_access_integrations": []
    },
    {
      "name": "dbt_test_task",
      "enabled": false,
      "warehouse": "TASTY_BYTES_DBT_WH",
      "dbt_command": "test",
      "target": "dev",
      "depends_on": ["dbt_run_task"],
      "external_access_integrations": []
    },
    {
      "name": "dbt_snapshot_task",
      "enabled": true,
      "warehouse": "TASTY_BYTES_DBT_WH",
      "dbt_command": "snapshot",
      "depends_on": ["dbt_run_task"],
      "external_access_integrations": []
    },
    {
      "name": "dbt_docs_task",
      "enabled": false,
      "warehouse": "TASTY_BYTES_DBT_WH",
      "dbt_command": "docs generate",
      "depends_on": ["dbt_test_task"],
      "external_access_integrations": []
    }
  ]
}
*/