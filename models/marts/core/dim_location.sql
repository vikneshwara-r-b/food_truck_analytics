-- Pseudocode Logic:
-- 1. Use cleaned location staging data
-- 2. Apply SCD Type-1 updates
-- 3. Add location analytics attributes

{{ config(
    materialized='table',
    tags=['core', 'dimension']
) }}

WITH location_current AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['location_id']) }} AS location_sk,
        location_id,
        placekey,
        location_name,
        city_name,
        region_name,
        country_name,
        iso_country_code,
        location_type,
        estimated_foot_traffic,
        
        -- Add coordinates (placeholder for future geocoding)
        NULL AS latitude,
        NULL AS longitude,
        
        -- Add business potential score
        CASE 
            WHEN location_type = 'Downtown' AND estimated_foot_traffic = 'High' THEN 95
            WHEN location_type = 'Business District' AND estimated_foot_traffic = 'High' THEN 90
            WHEN location_type = 'University' AND estimated_foot_traffic = 'Medium' THEN 85
            WHEN location_type = 'Market' AND estimated_foot_traffic = 'Medium' THEN 80
            WHEN location_type = 'Park' AND estimated_foot_traffic = 'Medium' THEN 75
            WHEN location_type = 'Event' THEN 70
            ELSE 60
        END AS business_potential_score,
        
        TRUE AS is_active,
        created_ts,
        CURRENT_TIMESTAMP() AS updated_ts
        
    FROM {{ ref('stg_pos_locations') }}
    WHERE location_id IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY updated_ts DESC) = 1
)

SELECT * FROM location_current