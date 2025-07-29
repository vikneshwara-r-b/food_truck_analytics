-- Pseudocode Logic:
-- 1. Aggregate menu item performance
-- 2. Calculate profitability and popularity metrics
-- 3. Add competitive analysis and rankings
-- 4. Include trend analysis

{{ config(
    materialized='table',
    tags=['analytics', 'menu']
) }}

WITH menu_performance_base AS (
    SELECT
        dd.date_actual AS analysis_date,
        fod.menu_item_sk,
        dm.menu_item_name,
        dm.truck_brand_name,
        dm.item_category,
        dm.item_subcategory,
        dm.sale_price_usd,
        dm.cost_of_goods_usd,
        dm.is_vegetarian,
        dm.is_vegan,
        dm.is_gluten_free,
        dm.menu_matrix_classification,
        
        -- Sales metrics
        SUM(fod.quantity) AS total_quantity_sold,
        COUNT(DISTINCT fod.order_sk) AS orders_containing_item,
        SUM(fod.line_total) AS total_revenue,
        SUM(fod.line_cost_of_goods) AS total_cost_of_goods,
        SUM(fod.line_profit) AS total_profit,
        AVG(fod.unit_price) AS avg_selling_price,
        SUM(fod.line_discount_amount) AS total_discounts_given,
        
        -- Penetration metrics
        COUNT(DISTINCT dt.truck_id) AS trucks_selling_item,
        COUNT(DISTINCT fo.customer_sk) AS unique_customers,
        
        -- Channel performance
        SUM(CASE WHEN fo.order_channel = 'Mobile App' THEN fod.quantity ELSE 0 END) AS mobile_quantity,
        SUM(CASE WHEN fo.order_channel = 'Walk-up' THEN fod.quantity ELSE 0 END) AS walkin_quantity,
        
        -- Time-based performance
        SUM(CASE WHEN fo.meal_period = 'Breakfast' THEN fod.quantity ELSE 0 END) AS breakfast_quantity,
        SUM(CASE WHEN fo.meal_period = 'Lunch' THEN fod.quantity ELSE 0 END) AS lunch_quantity,
        SUM(CASE WHEN fo.meal_period = 'Dinner' THEN fod.quantity ELSE 0 END) AS dinner_quantity
        
    FROM {{ ref('fact_order_detail') }} fod
    JOIN {{ ref('fact_order') }} fo ON fod.order_sk = fo.order_sk
    JOIN {{ ref('dim_date') }} dd ON fo.order_date_sk = dd.date_sk
    JOIN {{ ref('dim_menu_item') }} dm ON fod.menu_item_sk = dm.menu_item_sk
    JOIN {{ ref('dim_truck') }} dt ON fo.truck_sk = dt.truck_sk
    
    WHERE fod.menu_item_sk != '-1'
        
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
),

menu_performance_enhanced AS (
    SELECT
        *,
        
        -- Calculate profitability metrics
        CASE 
            WHEN total_revenue > 0 
            THEN (total_profit / total_revenue) * 100
            ELSE 0
        END AS profit_margin_pct,
        
        -- Performance rankings
        ROW_NUMBER() OVER (
            PARTITION BY analysis_date 
            ORDER BY total_quantity_sold DESC
        ) AS popularity_rank,
        
        ROW_NUMBER() OVER (
            PARTITION BY analysis_date 
            ORDER BY total_revenue DESC
        ) AS revenue_rank,
        
        ROW_NUMBER() OVER (
            PARTITION BY analysis_date 
            ORDER BY total_profit DESC
        ) AS profit_rank,
        
        -- Category rankings
        ROW_NUMBER() OVER (
            PARTITION BY analysis_date, item_category 
            ORDER BY total_quantity_sold DESC
        ) AS category_popularity_rank,
        
        -- Peak meal period
        CASE 
            WHEN GREATEST(breakfast_quantity, lunch_quantity, dinner_quantity) = breakfast_quantity THEN 'Breakfast'
            WHEN GREATEST(breakfast_quantity, lunch_quantity, dinner_quantity) = lunch_quantity THEN 'Lunch'
            WHEN GREATEST(breakfast_quantity, lunch_quantity, dinner_quantity) = dinner_quantity THEN 'Dinner'
            ELSE 'Even Distribution'
        END AS peak_meal_period,
        
        -- Channel preference
        CASE 
            WHEN mobile_quantity > walkin_quantity THEN 'Mobile Preferred'
            WHEN walkin_quantity > mobile_quantity THEN 'Walk-up Preferred'
            ELSE 'Balanced'
        END AS channel_preference,
        
        -- Performance classification
        CASE 
            WHEN total_quantity_sold >= 500 AND profit_margin_pct >= 60 THEN 'Star Performer'
            WHEN total_quantity_sold >= 500 AND profit_margin_pct < 60 THEN 'Volume Driver'
            WHEN total_quantity_sold < 100 AND profit_margin_pct >= 60 THEN 'Niche Premium'
            WHEN total_quantity_sold < 100 AND profit_margin_pct < 30 THEN 'Underperformer'
            ELSE 'Standard'
        END AS performance_classification,
        
        CURRENT_TIMESTAMP() AS created_ts,
        CURRENT_TIMESTAMP() AS updated_ts
        
    FROM menu_performance_base
)

SELECT * FROM menu_performance_enhanced