-- Pseudocode Logic:
-- 1. Generate time spine for intraday analysis
-- 2. Add time-based business attributes
-- 3. Include meal period classifications
-- Note: This table is created only if it doesn't exist (one-time creation)

{% set table_exists = adapter.get_relation(
    database=target.database,
    schema=var('schemas', {}).get('gold', target.schema ~ '_gold'),
    identifier='dim_time'
) %}

{% if table_exists is none %}
    {{ log('✨ Creating dim_time dimension table for the first time...', info=True) }}

{{ config(
    materialized='table',
    schema='gold'
) }}
{% else %}
    {{ log('⏭️  dim_time already exists, skipping creation', info=True) }}
    {{ config(
        materialized='table',
        schema='gold'
    ) }}
    
    -- Return empty result set to skip execution
    SELECT * FROM {{ table_exists }} WHERE 1=0
    
{% endif %}

{% if table_exists is none %}

WITH time_spine AS (
    SELECT
        DATEADD('minute', 
            ROW_NUMBER() OVER (ORDER BY 1) - 1, 
            '00:00:00'::TIME
        ) AS time_actual
    FROM TABLE(GENERATOR(ROWCOUNT => 1440))  -- 24 hours * 60 minutes
),

time_attributes AS (
    SELECT
        -- Generate surrogate key
        EXTRACT(HOUR FROM time_actual) * 100 + EXTRACT(MINUTE FROM time_actual) AS time_sk,
        time_actual,
        
        -- Hour attributes
        EXTRACT(HOUR FROM time_actual) AS hour_24,
        CASE 
            WHEN EXTRACT(HOUR FROM time_actual) = 0 THEN 12
            WHEN EXTRACT(HOUR FROM time_actual) <= 12 THEN EXTRACT(HOUR FROM time_actual)
            ELSE EXTRACT(HOUR FROM time_actual) - 12
        END AS hour_12,
        
        CASE 
            WHEN EXTRACT(HOUR FROM time_actual) < 12 THEN 'AM'
            ELSE 'PM'
        END AS am_pm,
        
        -- Minute attributes
        EXTRACT(MINUTE FROM time_actual) AS minute_number,
        
        -- Formatted time
        TO_CHAR(time_actual, 'HH24:MI') AS hour_minute,
        
        -- Day part classification
        CASE 
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 0 AND 5 THEN 'Late Night'
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 6 AND 11 THEN 'Morning'
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 12 AND 17 THEN 'Afternoon'
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 18 AND 21 THEN 'Evening'
            ELSE 'Night'
        END AS day_part,
        
        -- Meal period classification for food truck business
        CASE 
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 6 AND 10 THEN 'Breakfast'
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 11 AND 14 THEN 'Lunch'
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 15 AND 17 THEN 'Snack'
            WHEN EXTRACT(HOUR FROM time_actual) BETWEEN 18 AND 21 THEN 'Dinner'
            ELSE 'Off Hours'
        END AS meal_period
        
    FROM time_spine
)

SELECT * FROM time_attributes

{% endif %}
