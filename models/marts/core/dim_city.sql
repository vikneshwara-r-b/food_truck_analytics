-- Pseudocode Logic:
-- 1. Use cleaned country and city data
-- 2. Create city dimension with country relationship
-- 3. Add population and timezone information

{{ config(
    materialized='table',
    tags=['core', 'dimension']
) }}

WITH cities_with_countries AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['c.city_id']) }} AS city_sk,
        c.city_id,
        c.city_name,
        {{ dbt_utils.generate_surrogate_key(['c.country_id']) }} AS country_sk,
        c.population,
        
        -- Add timezone based on country
        CASE 
            WHEN co.iso_country = 'US' THEN 'America/New_York'  -- Simplified for US
            WHEN co.iso_country = 'CA' THEN 'America/Toronto'
            WHEN co.iso_country = 'GB' THEN 'Europe/London'
            WHEN co.iso_country = 'FR' THEN 'Europe/Paris'
            WHEN co.iso_country = 'DE' THEN 'Europe/Berlin'
            WHEN co.iso_country = 'JP' THEN 'Asia/Tokyo'
            WHEN co.iso_country = 'AU' THEN 'Australia/Sydney'
            ELSE 'UTC'
        END AS timezone,
        
        TRUE AS is_active,
        c.created_ts,
        CURRENT_TIMESTAMP() AS updated_ts
        
    FROM {{ ref('stg_pos_countries') }} c
    LEFT JOIN {{ ref('stg_pos_countries') }} co ON c.country_id = co.country_id
    WHERE c.city_id IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.city_id ORDER BY c.updated_ts DESC) = 1
)

SELECT * FROM cities_with_countries