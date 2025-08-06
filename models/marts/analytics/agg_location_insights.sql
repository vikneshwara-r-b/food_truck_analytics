-- Pseudocode Logic:
-- 1. Analyze location performance and patterns
-- 2. Calculate foot traffic and revenue potential
-- 3. Add peak hours and optimal positioning
-- 4. Include competitive analysis

{{ config(
    materialized='table',
    tags=['analytics', 'location']
) }}

WITH location_daily_performance AS (
    SELECT
        fo.location_sk,
        dd.date_actual AS analysis_date,
        dl.location_name,
        dl.city_name,
        dl.country_name,
        dl.location_type,
        dl.estimated_foot_traffic,
        dl.business_potential_score,
        
        -- Daily metrics
        COUNT(DISTINCT fo.order_id) AS daily_orders,
        SUM(fo.order_total) AS daily_revenue,
        COUNT(DISTINCT fo.truck_sk) AS trucks_served,
        COUNT(DISTINCT fo.customer_sk) AS unique_customers,
        AVG(fo.order_total) AS avg_order_value,
        AVG(fo.processing_time_minutes) AS avg_processing_time,
        
        -- Hourly distribution
        COUNT(DISTINCT CASE WHEN fo.order_hour BETWEEN 6 AND 10 THEN fo.order_id END) AS breakfast_orders,
        COUNT(DISTINCT CASE WHEN fo.order_hour BETWEEN 11 AND 14 THEN fo.order_id END) AS lunch_orders,
        COUNT(DISTINCT CASE WHEN fo.order_hour BETWEEN 15 AND 17 THEN fo.order_id END) AS snack_orders,
        COUNT(DISTINCT CASE WHEN fo.order_hour BETWEEN 18 AND 21 THEN fo.order_id END) AS dinner_orders,
        
        -- Day of week patterns
        dd.day_of_week,
        dd.day_of_week_name,
        dd.is_weekend,
        
        -- Weather impact (placeholder for future weather data integration)
        CASE 
            WHEN dd.month_number IN (12, 1, 2) THEN 'Winter'
            WHEN dd.month_number IN (3, 4, 5) THEN 'Spring'
            WHEN dd.month_number IN (6, 7, 8) THEN 'Summer'
            ELSE 'Fall'
        END AS season
        
    FROM {{ ref('fact_order') }} fo
    JOIN {{ ref('dim_date') }} dd ON fo.order_date_sk = dd.date_sk
    LEFT JOIN {{ ref('dim_location') }} dl ON fo.location_sk = dl.location_sk
    
    WHERE fo.location_sk != '-1'
        
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 19, 20, 21, 22
),

location_aggregated AS (
    SELECT
        location_sk,
        analysis_date,
        location_name,
        city_name,
        country_name,
        location_type,
        estimated_foot_traffic,
        business_potential_score,
        season,
        
        -- Aggregate daily metrics
        daily_orders,
        daily_revenue,
        trucks_served,
        unique_customers,
        avg_order_value,
        avg_processing_time,
        
        -- Hourly metrics
        breakfast_orders,
        lunch_orders,
        snack_orders,
        dinner_orders,
        
        -- Peak period analysis
        CASE 
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = breakfast_orders THEN '06:00'
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = lunch_orders THEN '12:00'
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = snack_orders THEN '15:00'
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = dinner_orders THEN '18:00'
            ELSE '12:00'
        END AS peak_hour_start,
        
        CASE 
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = breakfast_orders THEN '10:00'
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = lunch_orders THEN '14:00'
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = snack_orders THEN '17:00'
            WHEN GREATEST(breakfast_orders, lunch_orders, snack_orders, dinner_orders) = dinner_orders THEN '21:00'
            ELSE '14:00'
        END AS peak_hour_end,
        
        -- Day patterns
        day_of_week_name,
        is_weekend,
        
        -- Performance ratios
        CASE 
            WHEN trucks_served > 0 
            THEN daily_revenue / trucks_served
            ELSE 0
        END AS revenue_per_truck,
        
        CASE 
            WHEN trucks_served > 0 
            THEN daily_orders / trucks_served
            ELSE 0
        END AS orders_per_truck
        
    FROM location_daily_performance
),

location_insights_enhanced AS (
    SELECT
        location_sk,
        analysis_date,
        location_name,
        city_name,
        country_name,
        location_type,
        estimated_foot_traffic,
        business_potential_score,
        
        -- Performance metrics
        daily_orders,
        daily_revenue,
        trucks_served,
        unique_customers,
        avg_order_value,
        revenue_per_truck,
        orders_per_truck,
        peak_hour_start,
        peak_hour_end,
        
        -- Day of week analysis
        FIRST_VALUE(day_of_week_name) OVER (
            PARTITION BY location_sk, DATE_TRUNC('month', analysis_date) 
            ORDER BY daily_revenue DESC
        ) AS busiest_day_of_week,
        
        -- Weekend vs weekday performance
        AVG(CASE WHEN is_weekend THEN daily_revenue ELSE NULL END) OVER (
            PARTITION BY location_sk, DATE_TRUNC('month', analysis_date)
        ) AS avg_weekend_revenue,
        
        AVG(CASE WHEN NOT is_weekend THEN daily_revenue ELSE NULL END) OVER (
            PARTITION BY location_sk, DATE_TRUNC('month', analysis_date)
        ) AS avg_weekday_revenue,
        
        -- Performance rankings
        ROW_NUMBER() OVER (
            PARTITION BY analysis_date 
            ORDER BY daily_revenue DESC
        ) AS daily_revenue_rank,
        
        ROW_NUMBER() OVER (
            PARTITION BY analysis_date 
            ORDER BY revenue_per_truck DESC
        ) AS efficiency_rank,
        
        -- Moving averages (7-day)
        AVG(daily_revenue) OVER (
            PARTITION BY location_sk
            ORDER BY analysis_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS revenue_7day_avg,
        
        AVG(daily_orders) OVER (
            PARTITION BY location_sk
            ORDER BY analysis_date 
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS orders_7day_avg,
        
        -- Seasonal performance
        AVG(daily_revenue) OVER (
            PARTITION BY location_sk, season
        ) AS seasonal_avg_revenue,
        
        CURRENT_TIMESTAMP() AS created_ts,
        CURRENT_TIMESTAMP() AS updated_ts
        
    FROM location_aggregated
),

location_final AS (
    SELECT
        *,
        
        -- Weekend vs weekday ratio
        CASE 
            WHEN avg_weekday_revenue > 0 
            THEN avg_weekend_revenue / avg_weekday_revenue
            ELSE 0
        END AS weekend_vs_weekday_ratio,
        
        -- Foot traffic score (actual vs estimated)
        CASE 
            WHEN business_potential_score > 0
            THEN (daily_revenue / business_potential_score) * 100
            ELSE 0
        END AS foot_traffic_score,
        
        -- Revenue potential score
        CASE 
            WHEN revenue_7day_avg >= seasonal_avg_revenue * 1.2 THEN 95
            WHEN revenue_7day_avg >= seasonal_avg_revenue * 1.1 THEN 85
            WHEN revenue_7day_avg >= seasonal_avg_revenue * 0.9 THEN 75
            WHEN revenue_7day_avg >= seasonal_avg_revenue * 0.8 THEN 65
            ELSE 50
        END AS revenue_potential_score,
        
        -- Location performance category
        CASE 
            WHEN daily_revenue_rank <= 5 THEN 'Premium Location'
            WHEN daily_revenue_rank <= 15 THEN 'High Performing'
            WHEN daily_revenue_rank <= 30 THEN 'Standard'
            ELSE 'Underperforming'
        END AS location_performance_category
        
    FROM location_insights_enhanced
)

SELECT * FROM location_final