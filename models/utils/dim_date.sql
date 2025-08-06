-- Pseudocode Logic:
-- 1. Generate date spine for business calendar
-- 2. Add all date attributes needed for analysis
-- 3. Include fiscal calendar and holidays

{{ config(
    materialized='table',
    schema='gold'
) }}

WITH date_spine AS (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('" ~ var('date_spine_start') ~ "' as date)",
        end_date="cast('" ~ var('date_spine_end') ~ "' as date)"
    ) }}
),

date_attributes AS (
    SELECT
        -- Generate surrogate key
        TO_NUMBER(TO_CHAR(date_day, 'YYYYMMDD')) AS date_sk,
        date_day AS date_actual,
        
        -- Day attributes
        EXTRACT(DAY FROM date_day) AS day_of_month,
        EXTRACT(DAYOFYEAR FROM date_day) AS day_of_year,
        EXTRACT(DAYOFWEEK FROM date_day) AS day_of_week,
        TO_CHAR(date_day, 'DAY') AS day_of_week_name,
        
        -- Week attributes
        EXTRACT(WEEK FROM date_day) AS week_of_year,
        
        -- Month attributes
        EXTRACT(MONTH FROM date_day) AS month_number,
        TO_CHAR(date_day, 'MONTH') AS month_name,
        TO_CHAR(date_day, 'MON') AS month_short_name,
        
        -- Quarter attributes
        EXTRACT(QUARTER FROM date_day) AS quarter_number,
        'Q' || EXTRACT(QUARTER FROM date_day) AS quarter_name,
        
        -- Year attributes
        EXTRACT(YEAR FROM date_day) AS year_number,
        
        -- Business day flags
        CASE 
            WHEN EXTRACT(DAYOFWEEK FROM date_day) IN (0, 6) THEN TRUE
            ELSE FALSE
        END AS is_weekend,
        
        CASE 
            WHEN EXTRACT(DAYOFWEEK FROM date_day) BETWEEN 1 AND 5 THEN TRUE
            ELSE FALSE
        END AS is_weekday,
        
        -- Fiscal year (assuming April 1 start)
        CASE 
            WHEN EXTRACT(MONTH FROM date_day) >= 4 
            THEN EXTRACT(YEAR FROM date_day)
            ELSE EXTRACT(YEAR FROM date_day) - 1
        END AS fiscal_year,
        
        CASE 
            WHEN EXTRACT(MONTH FROM date_day) BETWEEN 4 AND 6 THEN 1
            WHEN EXTRACT(MONTH FROM date_day) BETWEEN 7 AND 9 THEN 2
            WHEN EXTRACT(MONTH FROM date_day) BETWEEN 10 AND 12 THEN 3
            ELSE 4
        END AS fiscal_quarter,
        
        CASE 
            WHEN EXTRACT(MONTH FROM date_day) >= 4 
            THEN EXTRACT(MONTH FROM date_day) - 3
            ELSE EXTRACT(MONTH FROM date_day) + 9
        END AS fiscal_month,
        
        -- Holiday flags (basic US holidays)
        CASE 
            -- New Year's Day
            WHEN EXTRACT(MONTH FROM date_day) = 1 AND EXTRACT(DAY FROM date_day) = 1 THEN TRUE
            -- Independence Day
            WHEN EXTRACT(MONTH FROM date_day) = 7 AND EXTRACT(DAY FROM date_day) = 4 THEN TRUE
            -- Christmas
            WHEN EXTRACT(MONTH FROM date_day) = 12 AND EXTRACT(DAY FROM date_day) = 25 THEN TRUE
            ELSE FALSE
        END AS is_holiday,
        
        CASE 
            WHEN EXTRACT(MONTH FROM date_day) = 1 AND EXTRACT(DAY FROM date_day) = 1 THEN 'New Year''s Day'
            WHEN EXTRACT(MONTH FROM date_day) = 7 AND EXTRACT(DAY FROM date_day) = 4 THEN 'Independence Day'
            WHEN EXTRACT(MONTH FROM date_day) = 12 AND EXTRACT(DAY FROM date_day) = 25 THEN 'Christmas Day'
            ELSE NULL
        END AS holiday_name
        
    FROM date_spine
)

SELECT * FROM date_attributes