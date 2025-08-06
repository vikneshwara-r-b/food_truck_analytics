-- Pseudocode Logic:
-- 1. Aggregate daily sales by truck and location
-- 2. Calculate key performance metrics
-- 3. Add rankings and growth calculations
-- 4. Include sustainability metrics

{{ config(
    materialized='table',
    tags=['analytics', 'aggregation']
) }}

WITH daily_sales_base AS (
    SELECT
        dd.date_actual AS sales_date,
        fo.truck_sk,
        fo.location_sk,
        dt.country_name,
        dt.primary_city AS city_name,
        dt.truck_status,
        dt.is_electric_vehicle,
        dl.location_type,
        dl.estimated_foot_traffic,
        
        -- Core metrics
        COUNT(DISTINCT fo.order_id) AS total_orders,
        SUM(fo.order_total) AS total_revenue,
        SUM(fo.total_cost_of_goods) AS total_cost_of_goods,
        SUM(fo.order_profit) AS total_profit,
        AVG(fo.order_total) AS avg_order_value,
        COUNT(DISTINCT fo.customer_sk) AS unique_customers,
        AVG(fo.processing_time_minutes) AS avg_processing_time_minutes,
        
        -- Operational metrics
        SUM(fo.line_item_count) AS total_line_items,
        SUM(fo.total_items_ordered) AS total_items_sold,
        AVG(fo.line_item_count) AS avg_items_per_order,
        
        -- Channel breakdown
        COUNT(DISTINCT CASE WHEN fo.order_channel = 'Mobile App' THEN fo.order_id END) AS mobile_orders,
        COUNT(DISTINCT CASE WHEN fo.order_channel = 'Walk-up' THEN fo.order_id END) AS walkin_orders,
        
        -- Meal period breakdown
        COUNT(DISTINCT CASE WHEN fo.meal_period = 'Breakfast' THEN fo.order_id END) AS breakfast_orders,
        COUNT(DISTINCT CASE WHEN fo.meal_period = 'Lunch' THEN fo.order_id END) AS lunch_orders,
        COUNT(DISTINCT CASE WHEN fo.meal_period = 'Dinner' THEN fo.order_id END) AS dinner_orders,
        
        -- Customer behavior
        COUNT(DISTINCT CASE WHEN fo.discount_percentage > 0 THEN fo.order_id END) AS discounted_orders
        
    FROM {{ ref('fact_order') }} fo
    JOIN {{ ref('dim_date') }} dd ON fo.order_date_sk = dd.date_sk
    JOIN {{ ref('dim_truck') }} dt ON fo.truck_sk = dt.truck_sk
    LEFT JOIN {{ ref('dim_location') }} dl ON fo.location_sk = dl.location_sk
    
    WHERE fo.order_sk != '-1'  -- Valid orders only
        
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
),

daily_sales_enhanced AS (
    SELECT
        *,
        
        -- Calculate profit margin
        CASE 
            WHEN total_revenue > 0 
            THEN (total_profit / total_revenue) * 100
            ELSE 0
        END AS profit_margin_pct,
        
        -- Performance rankings by date
        ROW_NUMBER() OVER (
            PARTITION BY sales_date 
            ORDER BY total_revenue DESC
        ) AS daily_revenue_rank,
        
        ROW_NUMBER() OVER (
            PARTITION BY sales_date 
            ORDER BY total_orders DESC
        ) AS daily_order_rank,
        
        ROW_NUMBER() OVER (
            PARTITION BY sales_date 
            ORDER BY total_profit DESC
        ) AS daily_profit_rank,
        
        -- Moving averages (7-day)
        AVG(total_revenue) OVER (
            PARTITION BY truck_sk, location_sk
            ORDER BY sales_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS revenue_7day_avg,
        
        AVG(total_orders) OVER (
            PARTITION BY truck_sk, location_sk
            ORDER BY sales_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS orders_7day_avg,
        
        -- Growth calculations (compared to same day previous week)
        LAG(total_revenue, 7) OVER (
            PARTITION BY truck_sk, location_sk
            ORDER BY sales_date
        ) AS revenue_prev_week,
        
        LAG(total_orders, 7) OVER (
            PARTITION BY truck_sk, location_sk
            ORDER BY sales_date
        ) AS orders_prev_week,
        
        CURRENT_TIMESTAMP() AS created_ts,
        CURRENT_TIMESTAMP() AS updated_ts
        
    FROM daily_sales_base
),

daily_sales_final AS (
    SELECT
        *,
        
        -- Week-over-week growth
        CASE 
            WHEN revenue_prev_week > 0
            THEN ((total_revenue - revenue_prev_week) / revenue_prev_week) * 100
            ELSE 0
        END AS revenue_wow_growth_pct,
        
        CASE 
            WHEN orders_prev_week > 0
            THEN ((total_orders - orders_prev_week) / orders_prev_week) * 100
            ELSE 0
        END AS orders_wow_growth_pct
        
    FROM daily_sales_enhanced
)

SELECT * FROM daily_sales_final