-- Pseudocode Logic:
-- 1. Create comprehensive customer analytics
-- 2. Include behavioral patterns and preferences
-- 3. Calculate lifetime value and churn risk
-- 4. Add segmentation insights

{{ config(
    materialized='table',
    tags=['analytics', 'customer']
) }}

WITH customer_transaction_summary AS (
    SELECT
        fo.customer_sk,
        
        -- Transaction history
        COUNT(DISTINCT fo.order_id) AS total_orders,
        SUM(fo.order_total) AS total_spent,
        AVG(fo.order_total) AS avg_order_value,
        MIN(dd.date_actual) AS first_order_date,
        MAX(dd.date_actual) AS last_order_date,
        
        -- Frequency analysis
        CASE 
            WHEN COUNT(DISTINCT fo.order_id) > 1
            THEN DATEDIFF('day', MIN(dd.date_actual), MAX(dd.date_actual)) / (COUNT(DISTINCT fo.order_id) - 1)
            ELSE NULL
        END AS avg_days_between_orders,
        
        DATEDIFF('day', MAX(dd.date_actual), CURRENT_DATE()) AS days_since_last_order,
        
        -- Recent activity (last 90 days)
        COUNT(DISTINCT CASE 
            WHEN dd.date_actual >= CURRENT_DATE() - 90 
            THEN fo.order_id 
        END) AS orders_last_90_days,
        
        SUM(CASE 
            WHEN dd.date_actual >= CURRENT_DATE() - 90 
            THEN fo.order_total 
            ELSE 0 
        END) AS spent_last_90_days,
        
        -- Channel preferences
        COUNT(DISTINCT CASE WHEN fo.order_channel = 'Mobile App' THEN fo.order_id END) AS mobile_orders,
        COUNT(DISTINCT CASE WHEN fo.order_channel = 'Walk-up' THEN fo.order_id END) AS walkin_orders,
        COUNT(DISTINCT CASE WHEN fo.order_channel = 'Online' THEN fo.order_id END) AS online_orders,
        
        -- Meal period preferences
        COUNT(DISTINCT CASE WHEN fo.meal_period = 'Breakfast' THEN fo.order_id END) AS breakfast_orders,
        COUNT(DISTINCT CASE WHEN fo.meal_period = 'Lunch' THEN fo.order_id END) AS lunch_orders,
        COUNT(DISTINCT CASE WHEN fo.meal_period = 'Dinner' THEN fo.order_id END) AS dinner_orders,
        
        -- Location diversity
        COUNT(DISTINCT fo.location_sk) AS unique_locations_visited,
        COUNT(DISTINCT fo.truck_sk) AS unique_trucks_visited,
        
        -- Discount usage
        COUNT(DISTINCT CASE WHEN fo.discount_percentage > 0 THEN fo.order_id END) AS discounted_orders,
        AVG(fo.discount_percentage) AS avg_discount_percentage,
        
        -- Order characteristics
        AVG(fo.line_item_count) AS avg_items_per_order,
        AVG(fo.processing_time_minutes) AS avg_processing_time,
        
        -- Most frequent values
        MODE(dt.primary_city) AS preferred_city,
        MODE(dl.location_type) AS preferred_location_type
        
    FROM {{ ref('fact_order') }} fo
    JOIN {{ ref('dim_date') }} dd ON fo.order_date_sk = dd.date_sk
    LEFT JOIN {{ ref('dim_truck') }} dt ON fo.truck_sk = dt.truck_sk
    LEFT JOIN {{ ref('dim_location') }} dl ON fo.location_sk = dl.location_sk
    
    WHERE fo.customer_sk != '-1'
    GROUP BY fo.customer_sk
),

customer_menu_preferences AS (
    SELECT
        fo.customer_sk,
        
        -- Category preferences
        MODE(dm.item_category) AS favorite_category,
        MODE(dm.item_subcategory) AS favorite_subcategory,
        MODE(dm.truck_brand_name) AS favorite_brand,
        
        -- Dietary preferences
        SUM(CASE WHEN dm.is_vegetarian THEN fod.quantity ELSE 0 END) AS vegetarian_items_ordered,
        SUM(CASE WHEN dm.is_vegan THEN fod.quantity ELSE 0 END) AS vegan_items_ordered,
        SUM(CASE WHEN dm.is_gluten_free THEN fod.quantity ELSE 0 END) AS gluten_free_items_ordered,
        SUM(fod.quantity) AS total_items_ordered,
        
        -- Price sensitivity
        AVG(fod.unit_price) AS avg_item_price_preference,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fod.unit_price) AS median_item_price_preference
        
    FROM {{ ref('fact_order') }} fo
    JOIN {{ ref('fact_order_detail') }} fod ON fo.order_sk = fod.order_sk
    JOIN {{ ref('dim_menu_item') }} dm ON fod.menu_item_sk = dm.menu_item_sk
    
    WHERE fo.customer_sk != '-1'
    GROUP BY fo.customer_sk
),

customer_360_comprehensive AS (
    SELECT
        dc.customer_sk,
        dc.customer_id,
        dc.customer_name,
        dc.city_name,
        dc.country_name,
        dc.age_group,
        dc.gender,
        dc.marital_status,
        dc.sign_up_date,
        dc.customer_segment,
        dc.digital_engagement_level,
        dc.price_sensitivity,
        dc.customer_value_tier,
        
        -- Transaction metrics
        COALESCE(cts.total_orders, 0) AS total_orders,
        COALESCE(cts.total_spent, 0) AS total_spent,
        COALESCE(cts.avg_order_value, 0) AS avg_order_value,
        cts.first_order_date,
        cts.last_order_date,
        COALESCE(cts.days_since_last_order, 9999) AS days_since_last_order,
        cts.avg_days_between_orders,
        
        -- Recent activity
        COALESCE(cts.orders_last_90_days, 0) AS orders_last_90_days,
        COALESCE(cts.spent_last_90_days, 0) AS spent_last_90_days,
        
        -- Behavioral patterns
        COALESCE(cts.mobile_orders, 0) AS mobile_orders,
        COALESCE(cts.walkin_orders, 0) AS walkin_orders,
        COALESCE(cts.breakfast_orders, 0) AS breakfast_orders,
        COALESCE(cts.lunch_orders, 0) AS lunch_orders,
        COALESCE(cts.dinner_orders, 0) AS dinner_orders,
        
        -- Preferences
        cmp.favorite_category,
        cmp.favorite_subcategory,
        cmp.favorite_brand,
        cts.preferred_city,
        cts.preferred_location_type,
        
        -- Diversity metrics
        COALESCE(cts.unique_locations_visited, 0) AS unique_locations_visited,
        COALESCE(cts.unique_trucks_visited, 0) AS unique_trucks_visited,
        
        -- Discount behavior
        COALESCE(cts.discounted_orders, 0) AS discounted_orders,
        COALESCE(cts.avg_discount_percentage, 0) AS avg_discount_percentage,
        
        -- Operational metrics
        COALESCE(cts.avg_items_per_order, 0) AS avg_items_per_order,
        COALESCE(cts.avg_processing_time, 0) AS avg_processing_time,
        
        -- Dietary preferences
        CASE 
            WHEN cmp.total_items_ordered > 0
            THEN (cmp.vegetarian_items_ordered * 100.0 / cmp.total_items_ordered)
            ELSE 0
        END AS vegetarian_preference_pct,
        
        CASE 
            WHEN cmp.total_items_ordered > 0
            THEN (cmp.vegan_items_ordered * 100.0 / cmp.total_items_ordered)
            ELSE 0
        END AS vegan_preference_pct,
        
        -- Lifetime value calculation
        CASE 
            WHEN cts.avg_days_between_orders IS NOT NULL AND cts.avg_days_between_orders > 0
            THEN (cts.avg_order_value * (365 / cts.avg_days_between_orders)) * 2  -- 2-year projection
            WHEN cts.total_orders > 0
            THEN cts.total_spent * 1.5  -- Conservative multiplier
            ELSE dc.estimated_lifetime_value
        END AS calculated_lifetime_value,
        
        -- Churn risk scoring
        CASE 
            WHEN cts.days_since_last_order IS NULL THEN 1.0  -- Never ordered
            WHEN cts.days_since_last_order <= 7 THEN 0.0   -- Very recent
            WHEN cts.days_since_last_order <= 30 THEN 0.1  -- Recent
            WHEN cts.days_since_last_order <= 60 THEN 0.3  -- Moderate risk
            WHEN cts.days_since_last_order <= 90 THEN 0.6  -- High risk
            WHEN cts.days_since_last_order <= 180 THEN 0.8 -- Very high risk
            ELSE 0.95  -- Likely churned
        END AS churn_risk_score,
        
        -- Activity status
        CASE 
            WHEN cts.orders_last_90_days > 0 THEN TRUE
            ELSE FALSE
        END AS is_active_customer,
        
        -- Customer journey stage
        CASE 
            WHEN cts.total_orders = 0 THEN 'Prospect'
            WHEN cts.total_orders = 1 THEN 'First Purchase'
            WHEN cts.total_orders <= 3 AND cts.days_since_last_order <= 90 THEN 'Early Adopter'
            WHEN cts.total_orders > 3 AND cts.days_since_last_order <= 30 THEN 'Engaged'
            WHEN cts.total_orders > 10 AND cts.avg_days_between_orders <= 30 THEN 'Loyal'
            WHEN cts.days_since_last_order > 180 THEN 'Churned'
            ELSE 'At Risk'
        END AS customer_journey_stage,
        
        -- Channel preference
        CASE 
            WHEN COALESCE(cts.mobile_orders, 0) > COALESCE(cts.walkin_orders, 0) + COALESCE(cts.online_orders, 0) 
            THEN 'Mobile Dominant'
            WHEN COALESCE(cts.walkin_orders, 0) > COALESCE(cts.mobile_orders, 0) + COALESCE(cts.online_orders, 0) 
            THEN 'Walk-up Dominant'
            WHEN COALESCE(cts.online_orders, 0) > COALESCE(cts.mobile_orders, 0) + COALESCE(cts.walkin_orders, 0) 
            THEN 'Online Dominant'
            ELSE 'Multi-Channel'
        END AS channel_preference,
        
        -- Peak meal period
        CASE 
            WHEN GREATEST(
                COALESCE(cts.breakfast_orders, 0), 
                COALESCE(cts.lunch_orders, 0), 
                COALESCE(cts.dinner_orders, 0)
            ) = COALESCE(cts.breakfast_orders, 0) THEN 'Breakfast'
            WHEN GREATEST(
                COALESCE(cts.breakfast_orders, 0), 
                COALESCE(cts.lunch_orders, 0), 
                COALESCE(cts.dinner_orders, 0)
            ) = COALESCE(cts.lunch_orders, 0) THEN 'Lunch'
            WHEN GREATEST(
                COALESCE(cts.breakfast_orders, 0), 
                COALESCE(cts.lunch_orders, 0), 
                COALESCE(cts.dinner_orders, 0)
            ) = COALESCE(cts.dinner_orders, 0) THEN 'Dinner'
            ELSE 'No Clear Preference'
        END AS preferred_meal_period,
        
        CURRENT_TIMESTAMP() AS created_ts,
        CURRENT_TIMESTAMP() AS updated_ts
        
    FROM {{ ref('dim_customer') }} dc
    LEFT JOIN customer_transaction_summary cts ON dc.customer_sk = cts.customer_sk
    LEFT JOIN customer_menu_preferences cmp ON dc.customer_sk = cmp.customer_sk
)

SELECT * FROM customer_360_comprehensive