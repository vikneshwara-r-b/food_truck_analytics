-- =====================================================================
-- Dynamic dbt Task Generator - Snowflake SQL Implementation (Updated with Change Detection)
-- =====================================================================
-- This script reads JSON configuration from a Snowflake stage and 
-- generates CREATE TASK statements dynamically with feed-based organization
-- and task enable/disable functionality with change detection
-- =====================================================================

-- =====================================================================
-- STEP 1: CREATE INFRASTRUCTURE
-- =====================================================================

-- Create a stage for storing JSON configuration files
CREATE STAGE IF NOT EXISTS dbt_config_stage;

-- Create a table to store the parsed JSON configuration with change tracking
CREATE TABLE IF NOT EXISTS dbt_task_config (
    feed_name STRING,
    config_data VARIANT,
    config_hash STRING,
    loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    is_current BOOLEAN DEFAULT TRUE,
    CONSTRAINT pk_dbt_task_config PRIMARY KEY (feed_name, loaded_at)
);

-- Create a table to track task creation history
CREATE TABLE IF NOT EXISTS dbt_task_creation_log (
    feed_name STRING,
    config_hash STRING,
    tasks_created INTEGER,
    tasks_skipped INTEGER,
    execution_status STRING,
    executed_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    error_message STRING
);

-- =====================================================================
-- STEP 2: CONFIGURATION MANAGEMENT PROCEDURES WITH CHANGE DETECTION
-- =====================================================================

-- Procedure to calculate configuration hash for change detection
CREATE OR REPLACE PROCEDURE calculate_config_hash(config_data VARIANT)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    config_string STRING;
    config_hash STRING;
BEGIN
    -- Convert config to standardized string and calculate hash
    config_string := config_data::STRING;
    config_hash := SHA2(config_string, 256);
    RETURN config_hash;
END;
$$;

CREATE OR REPLACE PROCEDURE load_dbt_config(feed_name_param STRING, config_file_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    copy_sql STRING;
    temp_table_name STRING;
    work_table_name STRING;
    temp_count_table STRING;
    temp_new_config_table STRING;
    temp_current_config_table STRING;
    new_config_data VARIANT;
    new_config_hash STRING;
    current_config_hash STRING;
    config_count INTEGER;
    current_count INTEGER;
    timestamp_suffix STRING;
    
BEGIN
    -- Create a unique timestamp suffix for all temporary tables
    timestamp_suffix := REGEXP_REPLACE(CURRENT_TIMESTAMP()::STRING, '[ :\.-]', '_');
    
    -- Create unique temporary table names
    temp_table_name := 'temp_config_' || timestamp_suffix;
    work_table_name := 'work_config_' || timestamp_suffix;
    temp_count_table := 'temp_count_' || timestamp_suffix;
    temp_new_config_table := 'temp_new_config_' || timestamp_suffix;
    temp_current_config_table := 'temp_current_config_' || timestamp_suffix;
    
    -- Create temporary table for loading JSON
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_table_name || ' (json_data VARIANT)';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Load JSON data from stage
    copy_sql := 'COPY INTO ' || temp_table_name || '(json_data) ' ||
                'FROM @dbt_config_stage/' || config_file_name || ' ' ||
                'FILE_FORMAT = (TYPE = ''JSON'')';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Create work table with the JSON data AND calculate hash in one step
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || work_table_name || ' AS ' ||
                'SELECT json_data, MD5(TO_JSON(json_data)) as config_hash FROM ' || temp_table_name || ' LIMIT 1';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Check if we have any configuration data using dynamic table name
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_count_table || ' AS SELECT COUNT(*) as cnt FROM ' || work_table_name;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Use IDENTIFIER to reference the dynamic table name in static SQL
    SELECT cnt INTO config_count FROM IDENTIFIER(:temp_count_table);
    
    -- Clean up count table
    copy_sql := 'DROP TABLE IF EXISTS ' || temp_count_table;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- If no config data found, clean up and return error
    IF (config_count = 0) THEN
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
        RETURN 'Error: No configuration data found in file: ' || config_file_name;
    END IF;
    
    -- Get both the new configuration data AND hash from work table
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_new_config_table || ' AS SELECT json_data, config_hash FROM ' || work_table_name || ' LIMIT 1';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Use IDENTIFIER to reference the dynamic table name in static SQL
    SELECT json_data, config_hash INTO new_config_data, new_config_hash FROM IDENTIFIER(:temp_new_config_table);
    
    -- Don't clean up temp_new_config_table yet - we need it for INSERT
    
    -- Get the current configuration hash if exists using dynamic table name
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_current_config_table || ' AS ' ||
                'SELECT COALESCE(config_hash, '''') as current_hash ' ||
                'FROM dbt_task_config ' ||
                'WHERE feed_name = ''' || feed_name_param || ''' AND is_current = TRUE LIMIT 1';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Check if current config exists
    SELECT COUNT(*) INTO current_count FROM IDENTIFIER(:temp_current_config_table);
    
    IF (current_count > 0) THEN
        SELECT current_hash INTO current_config_hash FROM IDENTIFIER(:temp_current_config_table);
    ELSE
        current_config_hash := '';
    END IF;
    
    -- Clean up temp table
    copy_sql := 'DROP TABLE IF EXISTS ' || temp_current_config_table;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Check if there are changes
    IF (current_config_hash = '' OR current_config_hash <> new_config_hash) THEN
        -- Mark previous configurations as not current
        UPDATE dbt_task_config 
        SET is_current = FALSE 
        WHERE feed_name = :feed_name_param 
        AND is_current = TRUE;
        
        -- Insert new configuration using dynamic SQL to handle VARIANT properly
        copy_sql := 'INSERT INTO dbt_task_config (feed_name, config_data, config_hash, is_current) ' ||
                   'SELECT ?, json_data, ?, TRUE FROM ' || temp_new_config_table;
        EXECUTE IMMEDIATE :copy_sql USING (feed_name_param, new_config_hash);
        
        -- Clean up temporary tables
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_new_config_table);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_new_config_table);
        
        RETURN 'Configuration loaded successfully for feed: ' || feed_name_param || 
               ' (Changes detected - Hash: ' || new_config_hash || ')';
    ELSE
        -- Clean up temporary tables
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
        
        RETURN 'No changes detected for feed: ' || feed_name_param || 
               ' (Current hash: ' || current_config_hash || ')';
    END IF;
    
EXCEPTION
    WHEN OTHER THEN
        -- Clean up temporary tables in case of error
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_count_table);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_new_config_table);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_current_config_table);
        RETURN 'Error loading configuration: ' || SQLERRM;
END;
$$;

-- Procedure to check if configuration has changes
CREATE OR REPLACE PROCEDURE has_config_changes(feed_name_param STRING, config_file_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    copy_sql STRING;
    temp_table_name STRING;
    work_table_name STRING;
    temp_count_table STRING;
    temp_new_config_table STRING;
    temp_current_config_table STRING;
    new_config_data VARIANT;
    new_config_hash STRING;
    current_config_hash STRING;
    config_count INTEGER;
    current_count INTEGER;
    timestamp_suffix STRING;
    
BEGIN
    -- Create a unique timestamp suffix for all temporary tables
    timestamp_suffix := REGEXP_REPLACE(CURRENT_TIMESTAMP()::STRING, '[ :\.-]', '_');
    
    -- Create unique temporary table names
    temp_table_name := 'temp_config_check_' || timestamp_suffix;
    work_table_name := 'work_config_check_' || timestamp_suffix;
    temp_count_table := 'temp_count_check_' || timestamp_suffix;
    temp_new_config_table := 'temp_new_config_check_' || timestamp_suffix;
    temp_current_config_table := 'temp_current_config_check_' || timestamp_suffix;
    
    -- Create temporary table for loading JSON
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_table_name || ' (json_data VARIANT)';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Load JSON data from stage
    copy_sql := 'COPY INTO ' || temp_table_name || '(json_data) ' ||
                'FROM @dbt_config_stage/' || config_file_name || ' ' ||
                'FILE_FORMAT = (TYPE = ''JSON'')';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Create work table with the JSON data AND calculate hash in one step
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || work_table_name || ' AS ' ||
                'SELECT json_data, MD5(TO_JSON(json_data)) as config_hash FROM ' || temp_table_name || ' LIMIT 1';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Check if we have any configuration data using dynamic table name
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_count_table || ' AS SELECT COUNT(*) as cnt FROM ' || work_table_name;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Use IDENTIFIER to reference the dynamic table name in static SQL
    SELECT cnt INTO config_count FROM IDENTIFIER(:temp_count_table);
    
    -- Clean up count table
    copy_sql := 'DROP TABLE IF EXISTS ' || temp_count_table;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- If no config data found, clean up and return error
    IF (config_count = 0) THEN
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
        RETURN 'ERROR - No configuration data found in file: ' || config_file_name;
    END IF;
    
    -- Get both the new configuration data AND hash using dynamic table name
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_new_config_table || ' AS SELECT json_data, config_hash FROM ' || work_table_name || ' LIMIT 1';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Use IDENTIFIER to reference the dynamic table name in static SQL
    SELECT json_data, config_hash INTO new_config_data, new_config_hash FROM IDENTIFIER(:temp_new_config_table);
    
    -- Clean up temp table
    copy_sql := 'DROP TABLE IF EXISTS ' || temp_new_config_table;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Get the current configuration hash if exists using dynamic table name
    copy_sql := 'CREATE OR REPLACE TEMPORARY TABLE ' || temp_current_config_table || ' AS ' ||
                'SELECT config_hash ' ||
                'FROM dbt_task_config ' ||
                'WHERE feed_name = ''' || feed_name_param || ''' AND is_current = TRUE LIMIT 1';
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Check if current config exists
    SELECT COUNT(*) INTO current_count FROM IDENTIFIER(:temp_current_config_table);
    
    IF (current_count > 0) THEN
        SELECT config_hash INTO current_config_hash FROM IDENTIFIER(:temp_current_config_table);
    ELSE
        current_config_hash := NULL;
    END IF;
    
    -- Clean up temp table
    copy_sql := 'DROP TABLE IF EXISTS ' || temp_current_config_table;
    EXECUTE IMMEDIATE :copy_sql;
    
    -- Clean up main temporary tables
    EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
    EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
    
    -- Compare hashes and return result
    IF (current_config_hash IS NULL) THEN
        RETURN 'NEW_FEED - No existing configuration found for feed: ' || feed_name_param;
    ELSEIF (current_config_hash <> new_config_hash) THEN
        RETURN 'CHANGES_DETECTED - Current hash: ' || current_config_hash || ', New hash: ' || new_config_hash;
    ELSE
        RETURN 'NO_CHANGES - Hash: ' || current_config_hash;
    END IF;
    
EXCEPTION
    WHEN OTHER THEN
        -- Clean up all temporary tables in case of error
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :work_table_name);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_count_table);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_new_config_table);
        EXECUTE IMMEDIATE ('DROP TABLE IF EXISTS ' || :temp_current_config_table);
        RETURN 'ERROR - ' || SQLERRM;
END;
$$;

-- Updated procedure to validate JSON configuration for a specific feed (current version only)
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
    enabled BOOLEAN;
    depends_on STRING;
BEGIN
    -- Get the current configuration for the specified feed
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param AND is_current = TRUE
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists
    IF (config_data IS NULL) THEN
        RETURN 'Error: No current configuration found for feed: ' || feed_name_param || '. Please load a JSON file first.';
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
        enabled := tasks_array[i]:enabled::BOOLEAN;
        depends_on := tasks_array[i]:depends_on::STRING;
        
        IF (task_name IS NULL) THEN
            RETURN 'Error: Task ' || (i + 1)::STRING || ' is missing name field for feed: ' || feed_name_param;
        END IF;
        
        IF (dbt_command IS NULL) THEN
            RETURN 'Error: Task ' || (i + 1)::STRING || ' is missing dbt_command field for feed: ' || feed_name_param;
        END IF;
        
        IF (enabled IS NULL) THEN
            RETURN 'Error: Task ' || (i + 1)::STRING || ' is missing enabled field for feed: ' || feed_name_param;
        END IF;

        IF (depends_on IS NULL) THEN
            RETURN 'Error: Task ' || (i + 1)::STRING || ' is missing depends field for feed: ' || feed_name_param;
        END IF;      
        
    END FOR;
    
    RETURN validation_result;
END;
$$;

-- =====================================================================
-- STEP 3: UPDATED TASK GENERATION PROCEDURES WITH CHANGE DETECTION
-- =====================================================================

-- Updated procedure to generate task SQL dynamically (preview only)
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
    config_hash STRING;
BEGIN
    -- Get the current configuration for the specified feed
    SELECT config_data, config_hash INTO :config_data, :config_hash
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param AND is_current = TRUE
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No current configuration found for feed: ' || feed_name_param;
    END IF;
    
    -- Extract project configuration
    project_config := config_data:project_config;
    database_name := project_config:database::STRING;
    schema_name := project_config:schema::STRING;
    project_name := project_config:project_name::STRING;
    default_warehouse := project_config:default_warehouse::STRING;
    default_target := project_config:default_target::STRING;
    
    -- Generate header comment with hash
    header_comment := '-- Generated dbt Tasks for ' || project_name || ' (Feed: ' || feed_name_param || ')\n' ||
                     '-- Database: ' || database_name || '\n' ||
                     '-- Schema: ' || schema_name || '\n' ||
                     '-- Config Hash: ' || config_hash || '\n' ||
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
    final_sql := final_sql || '-- Config Hash: ' || config_hash || '\n';
    
    RETURN final_sql;
END;
$$;

-- =====================================================================
-- STEP 4: UPDATED TASK EXECUTION PROCEDURES WITH CHANGE DETECTION
-- =====================================================================

-- Updated procedure to execute the generated SQL only if changes are detected
CREATE OR REPLACE PROCEDURE execute_dbt_tasks_if_changed(feed_name_param STRING, config_file_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    change_check_result STRING;
    load_result STRING;
    execute_result STRING;
BEGIN
    -- First check if there are changes
    CALL has_config_changes(:feed_name_param, :config_file_name) INTO :change_check_result;
    
    -- If no changes, return early
    IF (STARTSWITH(change_check_result, 'NO_CHANGES')) THEN
        RETURN 'Skipping task creation - ' || change_check_result;
    END IF;
    
    -- If there are changes or it's a new feed, load the configuration
    IF (STARTSWITH(change_check_result, 'CHANGES_DETECTED') OR STARTSWITH(change_check_result, 'NEW_FEED')) THEN
        CALL load_dbt_config(:feed_name_param, :config_file_name) INTO :load_result;
        
        -- Check if load was successful
        IF (NOT STARTSWITH(load_result, 'Configuration loaded successfully')) THEN
            RETURN 'Error loading configuration: ' || load_result;
        END IF;
        
        -- Execute task creation
        CALL execute_dbt_tasks(:feed_name_param) INTO :execute_result;
        RETURN 'Changes detected - ' || execute_result;
    ELSE
        RETURN 'Error checking for changes: ' || change_check_result;
    END IF;
END;
$$;

-- Updated procedure to execute the generated SQL (create tasks) with logging
CREATE OR REPLACE PROCEDURE execute_dbt_tasks(feed_name_param STRING)
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
    config_hash STRING;
    execution_status STRING := 'SUCCESS';
    error_msg STRING := '';
BEGIN
    -- Get the current configuration for the specified feed
    SELECT config_data, config_hash INTO :config_data, :config_hash
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param AND is_current = TRUE
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No current configuration found for feed: ' || feed_name_param;
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
    
    -- Log the execution
    INSERT INTO dbt_task_creation_log (feed_name, config_hash, tasks_created, tasks_skipped, execution_status)
    VALUES (:feed_name_param, :config_hash, :tasks_created, :tasks_skipped, :execution_status);
    
    RETURN 'Successfully created ' || tasks_created::STRING || ' enabled dbt tasks for feed: ' || feed_name_param || 
           ' (Skipped ' || tasks_skipped::STRING || ' disabled tasks) - Config Hash: ' || config_hash;
EXCEPTION
    WHEN OTHER THEN
        execution_status := 'ERROR';
        error_msg := SQLERRM;
        
        -- Log the error
        INSERT INTO dbt_task_creation_log (feed_name, config_hash, tasks_created, tasks_skipped, execution_status, error_message)
        VALUES (:feed_name_param, COALESCE(:config_hash, 'unknown'), :tasks_created, :tasks_skipped, :execution_status, :error_msg);
        
        RETURN 'Error executing tasks for feed ' || feed_name_param || ': ' || error_msg || ' (Task: ' || COALESCE(task_name, 'unknown') || ')';
END;
$$;

-- =====================================================================
-- STEP 5: UPDATED TASK MANAGEMENT PROCEDURES
-- =====================================================================

-- Updated procedure to resume all enabled dbt tasks for a specific feed (excluding root task)
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
    WHERE feed_name = :feed_name_param AND is_current = TRUE
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No current configuration found for feed: ' || feed_name_param;
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
            IF (is_root_task = FALSE  OR (is_root_task = TRUE and schedule IS NULL)) THEN
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
           ' (Skipped ' || tasks_skipped::STRING || ' disabled tasks, ' || root_tasks_skipped::STRING || ' root task with schedule)';
END;
$$;

-- Updated procedure to drop all generated tasks for a specific feed
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
    suspend_sql STRING;
    enabled BOOLEAN;
    i INTEGER;
    tasks_dropped INTEGER := 0;
    tasks_skipped INTEGER := 0;
BEGIN
    -- Get the current configuration for the specified feed
    SELECT config_data INTO :config_data 
    FROM dbt_task_config 
    WHERE feed_name = :feed_name_param AND is_current = TRUE
    ORDER BY loaded_at DESC 
    LIMIT 1;
    
    -- Check if configuration exists for this feed
    IF (config_data IS NULL) THEN
        RETURN 'Error: No current configuration found for feed: ' || feed_name_param;
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
            IF (tasks_array[i]:schedule IS NOT NULL) THEN
                suspend_sql := 'ALTER TASK ' || task_full_name || ' SUSPEND;';
                EXECUTE IMMEDIATE :suspend_sql;
            END IF;
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
-- STEP 6: UPDATED MONITORING AND REPORTING PROCEDURES
-- =====================================================================

-- Updated procedure to list all feeds with task status summary and change tracking
CREATE OR REPLACE PROCEDURE list_all_feeds()
RETURNS TABLE (feed_name STRING, loaded_at TIMESTAMP_LTZ, config_hash STRING, total_tasks INTEGER, enabled_tasks INTEGER, disabled_tasks INTEGER, is_current BOOLEAN)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
        WITH feed_task_stats AS (
            SELECT 
                dtc.feed_name,
                dtc.loaded_at,
                dtc.config_hash,
                dtc.is_current,
                ARRAY_SIZE(dtc.config_data:tasks) as total_tasks,
                COUNT(CASE WHEN COALESCE(t.value:enabled::BOOLEAN, TRUE) = TRUE THEN 1 END) as enabled_tasks,
                COUNT(CASE WHEN COALESCE(t.value:enabled::BOOLEAN, TRUE) = FALSE THEN 1 END) as disabled_tasks
            FROM dbt_task_config dtc,
                 LATERAL FLATTEN(input => dtc.config_data:tasks) t
            GROUP BY dtc.feed_name, dtc.loaded_at, dtc.config_hash, dtc.is_current, dtc.config_data:tasks
        )
        SELECT 
            feed_name,
            loaded_at,
            config_hash,
            total_tasks,
            enabled_tasks,
            disabled_tasks,
            is_current
        FROM feed_task_stats
        WHERE is_current = TRUE
        ORDER BY feed_name, loaded_at DESC
    );
    RETURN TABLE(res);
END;
$$;

-- Updated procedure to show detailed task status for a specific feed (current version only)
CREATE OR REPLACE PROCEDURE show_feed_task_status(feed_name_param STRING) 
RETURNS TABLE (
    task_name STRING, 
    enabled BOOLEAN, 
    dbt_command STRING, 
    schedule STRING, 
    depends_on VARIANT,  -- Changed from ARRAY to VARIANT
    config_hash STRING
) 
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
            t.value:depends_on as depends_on,  -- No casting, returns VARIANT
            dtc.config_hash::STRING as config_hash  -- Explicit cast to STRING
        FROM dbt_task_config dtc, 
             TABLE(FLATTEN(dtc.config_data:tasks)) t 
        WHERE dtc.feed_name = :feed_name_param 
          AND dtc.is_current = TRUE 
        ORDER BY t.index 
    ); 
    RETURN TABLE(res); 
END; 
$$;

-- Procedure to show task creation log
CREATE OR REPLACE PROCEDURE show_task_creation_log(feed_name_param STRING DEFAULT NULL)
RETURNS TABLE (feed_name STRING, config_hash STRING, tasks_created INTEGER, tasks_skipped INTEGER, execution_status STRING, executed_at TIMESTAMP_LTZ, error_message STRING)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
    where_clause STRING;
BEGIN
    where_clause := '';
    IF (feed_name_param IS NOT NULL) THEN
        where_clause := ' WHERE feed_name = ''' || feed_name_param || '''';
    END IF;
    
    res := (
        SELECT 
            feed_name,
            config_hash,
            tasks_created,
            tasks_skipped,
            execution_status,
            executed_at,
            error_message
        FROM dbt_task_creation_log
        WHERE (:feed_name_param IS NULL OR feed_name = :feed_name_param)
        ORDER BY executed_at DESC
    );
    RETURN TABLE(res);
END;
$$;

-- =====================================================================
-- STEP 7: UPDATED MONITORING VIEWS
-- =====================================================================


-- View to show current feed configurations with hash
CREATE OR REPLACE VIEW current_feed_configs AS
SELECT 
    feed_name,
    config_hash,
    loaded_at,
    ARRAY_SIZE(config_data:tasks) as total_tasks,
    (
        SELECT COUNT(*)
        FROM TABLE(FLATTEN(config_data:tasks)) t
        WHERE COALESCE(t.value:enabled::BOOLEAN, TRUE) = TRUE
    ) as enabled_tasks,
    (
        SELECT COUNT(*)
        FROM TABLE(FLATTEN(config_data:tasks)) t
        WHERE COALESCE(t.value:enabled::BOOLEAN, TRUE) = FALSE
    ) as disabled_tasks
FROM dbt_task_config 
WHERE is_current = TRUE
ORDER BY feed_name;

-- =====================================================================
-- UPDATED USAGE EXAMPLES WITH CHANGE DETECTION
-- =====================================================================

-- 1. Upload your JSON configuration file to the stage
-- PUT file:///path/to/your/config.json @dbt_config_stage;

-- 2. Check if there are changes before loading (optional)
-- CALL has_config_changes('my_feed_name', 'config.json');

-- 3. Load the configuration into the table with feed name (only if changes detected)
-- CALL load_dbt_config('my_feed_name', 'config.json');

-- 4. Execute tasks only if configuration has changed
-- CALL execute_dbt_tasks_if_changed('my_feed_name', 'config.json');

-- 5. Validate the configuration for a specific feed
-- CALL validate_dbt_config('my_feed_name');

-- 6. Preview the generated SQL without executing for a specific feed
-- CALL preview_dbt_tasks('my_feed_name');

-- 7. Execute the task generation for a specific feed (if already loaded)
-- CALL execute_dbt_tasks('my_feed_name');

-- 8. Check created tasks
-- SHOW TASKS LIKE '%my_feed_name%';

-- 9. Resume tasks for a specific feed (if needed)
-- CALL resume_all_dbt_tasks('my_feed_name');

-- 10. Drop all tasks for a specific feed (if needed)
-- CALL drop_all_dbt_tasks('my_feed_name');

-- 11. List all feed configurations with task counts and current status
-- CALL list_all_feeds();

-- 12. Show task status for a specific feed
-- CALL show_feed_task_status('my_feed_name');


-- 14. Show task creation log
-- CALL show_task_creation_log(); -- All feeds
-- CALL show_task_creation_log('my_feed_name'); -- Specific feed

-- 15. View current configurations
-- SELECT * FROM current_feed_configs;

-- =====================================================================
-- AUTOMATED WORKFLOW EXAMPLE
-- =====================================================================
/*
-- Complete workflow with change detection:

-- Step 1: Check for changes
CALL has_config_changes('my_feed_name', 'config.json');

-- Step 2: Execute tasks only if changes detected (combines load + execute)
CALL execute_dbt_tasks_if_changed('my_feed_name', 'config.json');

-- Step 3: Resume child tasks if creation was successful
CALL resume_all_dbt_tasks('my_feed_name');

-- Step 4: Monitor execution
CALL show_task_creation_log('my_feed_name');
*/

-- =====================================================================
-- SAMPLE JSON CONFIGURATION FILE (config.json) - UNCHANGED
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