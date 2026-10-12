-- =============================================================================
-- 05_headline_metrics.sql   (SQLite)
-- Purpose : One row per headline metric (metric, value). The build saves them to
--           reports/headline_metrics.json and reconciles them against the
--           validated baseline in reports/baseline/headline_metrics_duckdb.json
--           (the DuckDB build that preceded the SQLite migration). The same
--           numbers are the reconciliation targets for the notebook and Power BI.
--
-- Convention: -- @metrics: <title>  -> query returns columns (metric, value)
-- =============================================================================

-- @metrics: Headline metrics
WITH e AS (SELECT * FROM fct_orders WHERE is_delivery_kpi_eligible),
mr AS (SELECT AVG(is_late) AS r FROM e),
v(ord, val) AS (
    SELECT 1, hours_purchase_to_approval FROM e
    UNION ALL SELECT 2, days_approval_to_carrier FROM e
    UNION ALL SELECT 3, days_carrier_to_customer FROM e
    UNION ALL SELECT 4, days_purchase_to_delivery FROM e
    UNION ALL SELECT 5, days_purchase_to_estimate FROM e
    -- on-time vs late split over orders with all three stages valid (notebook + Power BI chart)
    UNION ALL SELECT 6, days_carrier_to_customer FROM e WHERE is_lifecycle_valid AND is_late = 0
    UNION ALL SELECT 7, days_carrier_to_customer FROM e WHERE is_lifecycle_valid AND is_late = 1
    UNION ALL SELECT 8, days_approval_to_carrier FROM e WHERE is_lifecycle_valid AND is_late = 0
    UNION ALL SELECT 9, days_approval_to_carrier FROM e WHERE is_lifecycle_valid AND is_late = 1
),
ranked AS (
    SELECT ord, val, ROW_NUMBER() OVER (PARTITION BY ord ORDER BY val) - 1 AS i,
           COUNT(*) OVER (PARTITION BY ord) AS n
    FROM v WHERE val IS NOT NULL
),
pcts(p) AS (VALUES (0.5), (0.9)),
pct_values AS (
    SELECT r.ord, q.p,
           SUM(CASE WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER)
                    THEN r.val * (1 - (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER)))
                    WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER) + 1
                    THEN r.val * (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER))
                    ELSE 0 END) AS pv
    FROM ranked r CROSS JOIN pcts q GROUP BY r.ord, q.p
)
SELECT 'total_orders' AS metric, (SELECT COUNT(*) FROM fct_orders) AS value
UNION ALL SELECT 'delivery_kpi_orders', (SELECT COUNT(*) FROM e)
UNION ALL SELECT 'late_orders', (SELECT COUNT(*) FROM e WHERE is_late)
UNION ALL SELECT 'late_rate', (SELECT AVG(is_late) FROM e)
UNION ALL SELECT 'late_rate_timestamp_rule', (SELECT AVG(is_late_timestamp_rule) FROM e)
UNION ALL SELECT 'delivered_on_estimated_day', (SELECT COUNT(*) FROM e WHERE days_vs_estimate = 0)
UNION ALL SELECT 'reviewed_on_time_orders', (SELECT COUNT(review_score) FROM e WHERE NOT is_late)
UNION ALL SELECT 'reviewed_late_orders', (SELECT COUNT(review_score) FROM e WHERE is_late)
UNION ALL SELECT 'avg_review_on_time', (SELECT AVG(review_score) FROM e WHERE NOT is_late)
UNION ALL SELECT 'avg_review_late', (SELECT AVG(review_score) FROM e WHERE is_late)
UNION ALL SELECT 'avg_review_delivered', (SELECT AVG(review_score) FROM e)
UNION ALL SELECT 'avg_review_all_orders', (SELECT AVG(review_score) FROM fct_orders)
UNION ALL SELECT 'late_reviews_created_before_delivery_share',
          (SELECT AVG(review_created_before_delivery) FROM e WHERE is_late AND has_review)
UNION ALL SELECT 'avg_review_late_post_delivery_reviews',
          (SELECT AVG(review_score) FROM e WHERE is_late AND NOT review_created_before_delivery)
UNION ALL SELECT 'canceled_orders', (SELECT COUNT(*) FROM fct_orders WHERE order_status = 'canceled')
UNION ALL SELECT 'unavailable_orders', (SELECT COUNT(*) FROM fct_orders WHERE order_status = 'unavailable')
UNION ALL SELECT 'lifecycle_valid_orders', (SELECT COUNT(*) FROM fct_orders WHERE is_lifecycle_valid)
UNION ALL SELECT 'median_hours_purchase_to_approval', (SELECT pv FROM pct_values WHERE ord = 1 AND p = 0.5)
UNION ALL SELECT 'median_days_approval_to_carrier',   (SELECT pv FROM pct_values WHERE ord = 2 AND p = 0.5)
UNION ALL SELECT 'median_days_carrier_to_customer',   (SELECT pv FROM pct_values WHERE ord = 3 AND p = 0.5)
UNION ALL SELECT 'p90_days_carrier_to_customer',      (SELECT pv FROM pct_values WHERE ord = 3 AND p = 0.9)
UNION ALL SELECT 'median_days_purchase_to_delivery',  (SELECT pv FROM pct_values WHERE ord = 4 AND p = 0.5)
UNION ALL SELECT 'median_days_promised',              (SELECT pv FROM pct_values WHERE ord = 5 AND p = 0.5)
UNION ALL SELECT 'delivered_order_value_brl',
          (SELECT ROUND(SUM(order_value_brl), 2) FROM fct_orders WHERE status_group = 'delivered')
UNION ALL SELECT 'total_items_plus_freight_brl', (SELECT ROUND(SUM(order_value_brl), 2) FROM fct_orders)
UNION ALL SELECT 'total_payments_brl', (SELECT ROUND(SUM(payment_value_brl), 2) FROM fct_orders)
UNION ALL SELECT 'orders_main_payment_credit_card', (SELECT COUNT(*) FROM fct_orders WHERE main_payment_type = 'credit_card')
UNION ALL SELECT 'orders_main_payment_boleto', (SELECT COUNT(*) FROM fct_orders WHERE main_payment_type = 'boleto')
UNION ALL SELECT 'orders_main_payment_voucher', (SELECT COUNT(*) FROM fct_orders WHERE main_payment_type = 'voucher')
UNION ALL SELECT 'orders_main_payment_debit_card', (SELECT COUNT(*) FROM fct_orders WHERE main_payment_type = 'debit_card')
UNION ALL SELECT 'northeast_late_rate', (SELECT AVG(is_late) FROM e WHERE customer_region = 'Northeast')
UNION ALL SELECT 'rj_excess_late_orders',
          (SELECT COUNT(*) FILTER (WHERE is_late) - COUNT(*) * (SELECT r FROM mr) FROM e WHERE customer_state = 'RJ')
UNION ALL SELECT 'sp_to_rj_lane_excess_late_orders',
          (SELECT COUNT(*) FILTER (WHERE o.is_late) - COUNT(*) * (SELECT r FROM mr)
           FROM e o
           WHERE o.customer_state = 'RJ'
             AND EXISTS (SELECT 1 FROM order_sellers os JOIN dim_seller s ON s.seller_id = os.seller_id
                         WHERE os.order_id = o.order_id AND s.seller_state = 'SP'))   -- one row per (order, lane)
UNION ALL SELECT 'median_days_carrier_to_customer_on_time_valid_lifecycle', (SELECT pv FROM pct_values WHERE ord = 6 AND p = 0.5)
UNION ALL SELECT 'median_days_carrier_to_customer_late_valid_lifecycle',    (SELECT pv FROM pct_values WHERE ord = 7 AND p = 0.5)
UNION ALL SELECT 'median_days_approval_to_carrier_on_time_valid_lifecycle', (SELECT pv FROM pct_values WHERE ord = 8 AND p = 0.5)
UNION ALL SELECT 'median_days_approval_to_carrier_late_valid_lifecycle',    (SELECT pv FROM pct_values WHERE ord = 9 AND p = 0.5)
UNION ALL SELECT 'sp_to_rj_lane_delivered_orders',
          (SELECT COUNT(*) FROM e o WHERE o.customer_state = 'RJ'
             AND EXISTS (SELECT 1 FROM order_sellers os JOIN dim_seller s ON s.seller_id = os.seller_id
                         WHERE os.order_id = o.order_id AND s.seller_state = 'SP'))
UNION ALL SELECT 'bed_bath_table_delivered_orders',
          (SELECT COUNT(*) FROM order_categories oc JOIN e o ON o.order_id = oc.order_id WHERE oc.category = 'bed_bath_table');
