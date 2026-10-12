-- =============================================================================
-- 04_business_analysis.sql   (SQLite)
-- Purpose : Answer business questions Q1-Q9 from the analytics model.
--           Output of every @result query is saved to
--           reports/sql_results/04_business_analysis.md by build_database.py.
--
-- Shared definitions (see docs/methodology.md for the full rationale)
--   Delivery-KPI population : fct_orders.is_delivery_kpi_eligible = 1
--                             = status 'delivered' AND delivery date present
--                             (96,470 of 99,441 orders; exclusions logged in 03).
--   Late (primary)          : delivery CALENDAR DATE > estimated delivery date.
--   Late (sensitivity)      : delivery timestamp > estimated timestamp (midnight).
--   Late rate               : late orders / delivery-KPI orders, ORDER grain.
--                             Flags are 1/0, so AVG(is_late) is the late rate
--                             (NULL flags of non-eligible orders are ignored).
--   Order value (BRL)       : item price + freight. Not revenue to Olist, not profit.
--   Period                  : purchases 2016-09-04 to 2018-10-17; monthly trends use
--                             the complete window Jan-2017 to Aug-2018.
--   Small samples           : groups below a stated minimum are flagged or filtered,
--                             and every rate is shown with its denominator.
--   Percentiles             : continuous (linear interpolation) percentile computed
--                             with ROW_NUMBER/COUNT windows - see 02, section 7.
--   Rankings                : ORDER BY uses the UNROUNDED metric plus an ID
--                             tie-breaker, so ties in displayed values sort
--                             deterministically and in true order.
-- =============================================================================

-- =============================================================================
-- Q1. What share of delivered orders arrived later than the estimated date?
-- Grain: order. Numerator: late orders. Denominator: delivery-KPI orders.
-- =============================================================================
-- @result: Q1 Late-delivery rate, all delivered orders (primary and sensitivity definitions)
SELECT
    COUNT(*)                                                    AS delivered_orders_denominator,
    COUNT(*) FILTER (WHERE is_late)                             AS late_orders_calendar_date_rule,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 2) AS late_pct_calendar_date_rule,
    COUNT(*) FILTER (WHERE is_late_timestamp_rule)              AS late_orders_timestamp_rule,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late_timestamp_rule) / COUNT(*), 2) AS late_pct_timestamp_rule,
    COUNT(*) FILTER (WHERE days_vs_estimate = 0)                AS delivered_on_estimated_day,
    MIN(purchase_date)                                          AS first_purchase,
    MAX(purchase_date)                                          AS last_purchase
FROM fct_orders
WHERE is_delivery_kpi_eligible;

-- =============================================================================
-- Q2. How does the late rate vary by month, region/state, category and seller?
-- =============================================================================
-- Month = purchase month. Restricted to the complete window (Jan-2017..Aug-2018).
-- Caveat: Aug-2018 orders still in transit at the data cut-off are not yet
-- "delivered", so the most recent months may understate lateness.
-- @result: Q2a Monthly order volume and late-delivery rate (purchase month)
SELECT
    strftime('%Y-%m', purchase_month)                        AS purchase_month,
    COUNT(*)                                                 AS orders_placed,
    COUNT(*) FILTER (WHERE is_delivery_kpi_eligible)         AS delivered_orders,
    COUNT(*) FILTER (WHERE is_late)                          AS late_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
          / NULLIF(COUNT(*) FILTER (WHERE is_delivery_kpi_eligible), 0), 2) AS late_pct,
    ROUND(AVG(days_purchase_to_delivery), 1)                 AS avg_days_to_deliver,
    ROUND(AVG(days_purchase_to_estimate) FILTER (WHERE is_delivery_kpi_eligible), 1) AS avg_days_promised
FROM fct_orders
WHERE in_trend_window
GROUP BY purchase_month
ORDER BY purchase_month;

-- @result: Q2b Late-delivery rate by customer region
SELECT customer_region,
       COUNT(*)                                       AS delivered_orders,
       COUNT(*) FILTER (WHERE is_late)                AS late_orders,
       ROUND(100.0 * AVG(is_late), 2)                 AS late_pct,
       ROUND(AVG(days_purchase_to_delivery), 1)       AS avg_days_to_deliver,
       ROUND(AVG(days_purchase_to_estimate), 1)       AS avg_days_promised
FROM fct_orders
WHERE is_delivery_kpi_eligible
GROUP BY customer_region
ORDER BY late_pct DESC;

-- States with < 300 delivered orders are flagged as small samples.
-- @result: Q2c Late-delivery rate by customer state
SELECT customer_state,
       customer_region,
       COUNT(*)                                       AS delivered_orders,
       COUNT(*) FILTER (WHERE is_late)                AS late_orders,
       ROUND(100.0 * AVG(is_late), 2)                 AS late_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
             / SUM(COUNT(*) FILTER (WHERE is_late)) OVER (), 2) AS share_of_all_late_orders_pct,
       CASE WHEN COUNT(*) < 300 THEN 'small sample (<300)' ELSE '' END AS sample_flag
FROM fct_orders
WHERE is_delivery_kpi_eligible
GROUP BY customer_state, customer_region
ORDER BY AVG(is_late) DESC, customer_state;

-- Grain: (order, category) bridge. An order containing two categories counts
-- once in each (0.8% of orders); the order's single delivery date applies to both.
-- Categories with < 500 delivered orders are omitted from this ranking.
-- @result: Q2d Late-delivery rate by product category (>= 500 delivered orders)
SELECT oc.category,
       COUNT(*)                                       AS delivered_orders,
       COUNT(*) FILTER (WHERE o.is_late)              AS late_orders,
       ROUND(100.0 * AVG(o.is_late), 2)               AS late_pct,
       ROUND(AVG(o.review_score), 2)                  AS avg_review_score
FROM order_categories oc
JOIN fct_orders o USING (order_id)
WHERE o.is_delivery_kpi_eligible
GROUP BY oc.category
HAVING COUNT(*) >= 500
ORDER BY AVG(o.is_late) DESC, oc.category;

-- Seller distribution: how concentrated are sellers, and how many are too small to rank?
-- @result: Q2e Seller late-rate distribution by seller volume band
WITH seller_stats AS (
    SELECT os.seller_id,
           COUNT(*)                        AS delivered_orders,
           AVG(o.is_late)                  AS late_rate
    FROM order_sellers os
    JOIN fct_orders o USING (order_id)
    WHERE o.is_delivery_kpi_eligible
    GROUP BY os.seller_id
),
banded AS (
    SELECT *,
           CASE WHEN delivered_orders < 10  THEN '1: 1-9 orders (too small to rank)'
                WHEN delivered_orders < 50  THEN '2: 10-49 orders (small sample)'
                WHEN delivered_orders < 200 THEN '3: 50-199 orders'
                ELSE                             '4: 200+ orders' END AS seller_volume_band
    FROM seller_stats
),
ranked AS (
    SELECT seller_volume_band, late_rate,
           ROW_NUMBER() OVER (PARTITION BY seller_volume_band ORDER BY late_rate) - 1 AS i,
           COUNT(*) OVER (PARTITION BY seller_volume_band) AS n
    FROM banded
),
pcts(p) AS (VALUES (0.5), (0.9)),
pct_values AS (
    SELECT r.seller_volume_band AS band, q.p,
           SUM(CASE WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER)
                    THEN r.late_rate * (1 - (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER)))
                    WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER) + 1
                    THEN r.late_rate * (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER))
                    ELSE 0 END) AS pv
    FROM ranked r CROSS JOIN pcts q
    GROUP BY r.seller_volume_band, q.p
)
SELECT b.seller_volume_band,
       COUNT(*)                                      AS sellers,
       SUM(b.delivered_orders)                       AS delivered_orders,
       ROUND(100.0 * SUM(b.delivered_orders) / SUM(SUM(b.delivered_orders)) OVER (), 1) AS share_of_seller_orders_pct,
       ROUND(100.0 * (SELECT pv FROM pct_values x WHERE x.band = b.seller_volume_band AND x.p = 0.5), 2) AS median_seller_late_pct,
       ROUND(100.0 * (SELECT pv FROM pct_values x WHERE x.band = b.seller_volume_band AND x.p = 0.9), 2) AS p90_seller_late_pct
FROM banded b
GROUP BY b.seller_volume_band
ORDER BY b.seller_volume_band;

-- =============================================================================
-- Q3. Are late deliveries associated with lower review scores?
-- Grain: order (one review per order, see stg_order_review).
-- Population: delivery-KPI orders that have a review.
-- This is an ASSOCIATION. Late orders may differ in other ways (region,
-- category, seller), and reviews can be written before delivery.
-- Sample standard deviation = sqrt((sum(x^2) - sum(x)^2 / n) / (n - 1)).
-- =============================================================================
-- @result: Q3a Review score for on-time vs late orders (with 95% CI of the mean)
WITH s AS (
    SELECT CASE WHEN is_late THEN 'late' ELSE 'on time' END AS delivery_outcome,
           COUNT(*)                                 AS delivered_orders,
           COUNT(review_score)                      AS n,
           AVG(review_score)                        AS mean,
           SQRT((SUM(review_score * review_score) - 1.0 * SUM(review_score) * SUM(review_score) / COUNT(review_score))
                / (COUNT(review_score) - 1))        AS sd,
           AVG(review_score <= 2)                   AS low_share,
           AVG(review_score = 5)                    AS top_share
    FROM fct_orders
    WHERE is_delivery_kpi_eligible
    GROUP BY 1
)
SELECT delivery_outcome,
       delivered_orders,
       n                                            AS reviewed_orders,
       ROUND(mean, 3)                               AS avg_review_score,
       ROUND(mean - 1.96 * sd / SQRT(n), 3)         AS ci95_low,
       ROUND(mean + 1.96 * sd / SQRT(n), 3)         AS ci95_high,
       ROUND(100.0 * low_share, 1)                  AS pct_1_or_2_stars,
       ROUND(100.0 * top_share, 1)                  AS pct_5_stars
FROM s
ORDER BY delivery_outcome DESC;

-- @result: Q3b Difference in review outcomes, late minus on-time
WITH s AS (
    SELECT AVG(review_score) FILTER (WHERE is_late)                AS late_avg,
           AVG(review_score) FILTER (WHERE NOT is_late)            AS ontime_avg,
           AVG(review_score <= 2) FILTER (WHERE is_late)           AS late_low,
           AVG(review_score <= 2) FILTER (WHERE NOT is_late)       AS ontime_low,
           COUNT(review_score) FILTER (WHERE is_late)              AS n_late,
           COUNT(review_score) FILTER (WHERE NOT is_late)          AS n_ontime
    FROM fct_orders
    WHERE is_delivery_kpi_eligible
)
SELECT n_late AS reviewed_late_orders,
       n_ontime AS reviewed_on_time_orders,
       ROUND(late_avg - ontime_avg, 3)                 AS avg_score_difference,
       ROUND(100.0 * (late_low - ontime_low), 1)       AS low_score_share_difference_pp,
       ROUND(late_low / ontime_low, 2)                 AS low_score_share_ratio
FROM s;

-- Dose-response view: does the score fall further as the delay grows?
-- @result: Q3c Review score by days delivered relative to the estimate
SELECT CASE WHEN days_vs_estimate <= -15 THEN '1: 15+ days early'
            WHEN days_vs_estimate <= -8  THEN '2: 8-14 days early'
            WHEN days_vs_estimate <= -1  THEN '3: 1-7 days early'
            WHEN days_vs_estimate =  0   THEN '4: on the estimated day'
            WHEN days_vs_estimate <=  3  THEN '5: 1-3 days late'
            WHEN days_vs_estimate <=  7  THEN '6: 4-7 days late'
            WHEN days_vs_estimate <= 14  THEN '7: 8-14 days late'
            ELSE                              '8: 15+ days late' END AS delivery_vs_estimate,
       COUNT(*)                                        AS delivered_orders,
       COUNT(review_score)                             AS reviewed_orders,
       ROUND(AVG(review_score), 2)                     AS avg_review_score,
       ROUND(100.0 * AVG(review_score <= 2), 1)        AS pct_1_or_2_stars
FROM fct_orders
WHERE is_delivery_kpi_eligible
GROUP BY 1
ORDER BY 1;

-- Partial check for confounding by geography: compare within each region.
-- @result: Q3d On-time vs late review gap within each customer region
SELECT customer_region,
       COUNT(review_score) FILTER (WHERE NOT is_late)            AS reviewed_on_time,
       COUNT(review_score) FILTER (WHERE is_late)                AS reviewed_late,
       ROUND(AVG(review_score) FILTER (WHERE NOT is_late), 2)    AS avg_score_on_time,
       ROUND(AVG(review_score) FILTER (WHERE is_late), 2)        AS avg_score_late,
       ROUND(AVG(review_score) FILTER (WHERE is_late)
             - AVG(review_score) FILTER (WHERE NOT is_late), 2)  AS gap
FROM fct_orders
WHERE is_delivery_kpi_eligible
GROUP BY customer_region
ORDER BY customer_region;

-- @result: Q3e Review timing caveat - reviews created before the order was delivered
SELECT CASE WHEN is_late THEN 'late' ELSE 'on time' END AS delivery_outcome,
       COUNT(review_score)                                        AS reviewed_orders,
       COUNT(*) FILTER (WHERE review_created_before_delivery)     AS reviews_created_before_delivery,
       ROUND(100.0 * AVG(review_created_before_delivery), 1)      AS pct_created_before_delivery,
       ROUND(AVG(review_score) FILTER (WHERE NOT review_created_before_delivery), 2) AS avg_score_reviews_after_delivery
FROM fct_orders
WHERE is_delivery_kpi_eligible AND has_review
GROUP BY 1
ORDER BY 1 DESC;

-- =============================================================================
-- Q4. Which sellers / categories have meaningful volume AND a consistently
--     high late rate?
-- Volume threshold: sellers >= 100 delivered orders, categories >= 500.
-- "Consistently high": in quarters where the group had >= 10 delivered orders,
--   its late rate exceeded the marketplace rate for that same quarter in at
--   least 60% of those quarters (minimum 3 qualifying quarters).
-- wilson_lower_pct: 95% Wilson lower bound of the late rate - a conservative
--   rate that penalises small samples, used for ranking.
-- =============================================================================
-- @result: Q4a Sellers with >= 100 delivered orders and a consistently high late rate (top 20 by Wilson lower bound)
WITH orders_q AS (
    SELECT order_id, is_late,
           strftime('%Y', purchase_date) || '-Q' || ((CAST(strftime('%m', purchase_date) AS INTEGER) + 2) / 3) AS qtr
    FROM fct_orders WHERE is_delivery_kpi_eligible
),
quarterly_market AS (
    SELECT qtr, AVG(is_late) AS market_rate FROM orders_q GROUP BY qtr
),
seller_quarter AS (
    SELECT os.seller_id, o.qtr, COUNT(*) AS n, AVG(o.is_late) AS rate
    FROM order_sellers os
    JOIN orders_q o USING (order_id)
    GROUP BY 1, 2
),
consistency AS (
    SELECT sq.seller_id,
           COUNT(*) FILTER (WHERE sq.n >= 10)                                  AS qualifying_quarters,
           COUNT(*) FILTER (WHERE sq.n >= 10 AND sq.rate > qm.market_rate)     AS quarters_above_market
    FROM seller_quarter sq JOIN quarterly_market qm USING (qtr)
    GROUP BY 1
),
seller_totals AS (
    SELECT os.seller_id,
           COUNT(*)                                   AS delivered_orders,
           COUNT(*) FILTER (WHERE o.is_late)          AS late_orders,
           AVG(o.is_late)                             AS p,
           AVG(o.is_carrier_handoff_late)             AS handoff_late_rate,
           AVG(o.review_score)                        AS avg_review
    FROM order_sellers os
    JOIN fct_orders o USING (order_id)
    WHERE o.is_delivery_kpi_eligible
    GROUP BY 1
)
SELECT t.seller_id,
       s.seller_state,
       t.delivered_orders,
       t.late_orders,
       ROUND(100.0 * t.p, 2) AS late_pct,
       ROUND(100.0 * (t.p + 1.92 / t.delivered_orders
             - 1.96 * SQRT(t.p * (1 - t.p) / t.delivered_orders + 0.9604 / POWER(t.delivered_orders, 2)))
             / (1 + 3.8416 / t.delivered_orders), 2) AS wilson_lower_pct,
       c.quarters_above_market || ' of ' || c.qualifying_quarters AS quarters_above_market_rate,
       ROUND(100.0 * t.handoff_late_rate, 1) AS carrier_handoff_late_pct,
       ROUND(t.avg_review, 2) AS avg_review_score,
       COUNT(*) OVER () AS sellers_qualifying   -- total before LIMIT (top 20 shown)
FROM seller_totals t
JOIN consistency c USING (seller_id)
JOIN dim_seller s USING (seller_id)
WHERE t.delivered_orders >= 100
  AND c.qualifying_quarters >= 3
  AND c.quarters_above_market >= 0.6 * c.qualifying_quarters
ORDER BY (t.p + 1.92 / t.delivered_orders
          - 1.96 * SQRT(t.p * (1 - t.p) / t.delivered_orders + 0.9604 / POWER(t.delivered_orders, 2)))
          / (1 + 3.8416 / t.delivered_orders) DESC, t.seller_id   -- unrounded Wilson bound
LIMIT 20;

-- @result: Q4b Categories with >= 500 delivered orders and a consistently high late rate
WITH orders_q AS (
    SELECT order_id, is_late, review_score,
           strftime('%Y', purchase_date) || '-Q' || ((CAST(strftime('%m', purchase_date) AS INTEGER) + 2) / 3) AS qtr
    FROM fct_orders WHERE is_delivery_kpi_eligible
),
quarterly_market AS (
    SELECT qtr, AVG(is_late) AS market_rate FROM orders_q GROUP BY qtr
),
cat_quarter AS (
    SELECT oc.category, o.qtr, COUNT(*) AS n, AVG(o.is_late) AS rate
    FROM order_categories oc
    JOIN orders_q o USING (order_id)
    GROUP BY 1, 2
),
consistency AS (
    SELECT cq.category,
           COUNT(*) FILTER (WHERE cq.n >= 10)                              AS qualifying_quarters,
           COUNT(*) FILTER (WHERE cq.n >= 10 AND cq.rate > qm.market_rate) AS quarters_above_market
    FROM cat_quarter cq JOIN quarterly_market qm USING (qtr)
    GROUP BY 1
),
cat_totals AS (
    SELECT oc.category,
           COUNT(*) AS delivered_orders,
           COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
           AVG(o.is_late) AS p,
           AVG(o.review_score) AS avg_review
    FROM order_categories oc
    JOIN orders_q o USING (order_id)
    GROUP BY 1
)
SELECT t.category,
       t.delivered_orders,
       t.late_orders,
       ROUND(100.0 * t.p, 2) AS late_pct,
       ROUND(100.0 * (t.p + 1.92 / t.delivered_orders
             - 1.96 * SQRT(t.p * (1 - t.p) / t.delivered_orders + 0.9604 / POWER(t.delivered_orders, 2)))
             / (1 + 3.8416 / t.delivered_orders), 2) AS wilson_lower_pct,
       c.quarters_above_market || ' of ' || c.qualifying_quarters AS quarters_above_market_rate,
       ROUND(t.avg_review, 2) AS avg_review_score
FROM cat_totals t
JOIN consistency c USING (category)
WHERE t.delivered_orders >= 500
  AND c.qualifying_quarters >= 3
  AND c.quarters_above_market >= 0.6 * c.qualifying_quarters
ORDER BY (t.p + 1.92 / t.delivered_orders
          - 1.96 * SQRT(t.p * (1 - t.p) / t.delivered_orders + 0.9604 / POWER(t.delivered_orders, 2)))
          / (1 + 3.8416 / t.delivered_orders) DESC, t.category;   -- unrounded Wilson bound

-- =============================================================================
-- Q5. How long does each lifecycle stage take?
-- Population: delivery-KPI orders; each stage uses only rows where both
-- timestamps exist and are in order (exclusion counts in 03 results).
-- =============================================================================
-- @result: Q5a Lifecycle stage durations (delivered orders, valid sequences per stage)
WITH v(ord, stage, unit, val) AS (
    SELECT 1, 'purchase -> approval', 'hours', hours_purchase_to_approval FROM fct_orders WHERE is_delivery_kpi_eligible
    UNION ALL SELECT 2, 'approval -> handed to carrier', 'days', days_approval_to_carrier FROM fct_orders WHERE is_delivery_kpi_eligible
    UNION ALL SELECT 3, 'carrier -> customer', 'days', days_carrier_to_customer FROM fct_orders WHERE is_delivery_kpi_eligible
    UNION ALL SELECT 4, 'purchase -> customer (total)', 'days', days_purchase_to_delivery FROM fct_orders WHERE is_delivery_kpi_eligible
    UNION ALL SELECT 5, 'purchase -> estimated date (promise)', 'days', days_purchase_to_estimate FROM fct_orders WHERE is_delivery_kpi_eligible
),
ranked AS (
    SELECT ord, val,
           ROW_NUMBER() OVER (PARTITION BY ord ORDER BY val) - 1 AS i,
           COUNT(*) OVER (PARTITION BY ord) AS n
    FROM v WHERE val IS NOT NULL
),
pcts(p) AS (VALUES (0.5), (0.75), (0.9)),
pct_values AS (
    SELECT r.ord, q.p,
           SUM(CASE WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER)
                    THEN r.val * (1 - (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER)))
                    WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER) + 1
                    THEN r.val * (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER))
                    ELSE 0 END) AS pv
    FROM ranked r CROSS JOIN pcts q
    GROUP BY r.ord, q.p
)
SELECT v.stage,
       COUNT(v.val) AS valid_orders,
       ROUND((SELECT pv FROM pct_values x WHERE x.ord = v.ord AND x.p = 0.5), 1)  AS median_value,
       ROUND((SELECT pv FROM pct_values x WHERE x.ord = v.ord AND x.p = 0.75), 1) AS p75_value,
       ROUND((SELECT pv FROM pct_values x WHERE x.ord = v.ord AND x.p = 0.9), 1)  AS p90_value,
       ROUND(AVG(v.val), 1) AS mean_value,
       v.unit
FROM v
GROUP BY v.ord, v.stage, v.unit
ORDER BY v.ord;

-- Where does the extra time in late orders come from? (orders valid on all three stages)
-- @result: Q5b Median stage durations, on-time vs late orders
WITH v(outcome, metric, val) AS (
    SELECT is_late, 'approval_h', hours_purchase_to_approval FROM fct_orders WHERE is_lifecycle_valid
    UNION ALL SELECT is_late, 'to_carrier_d', days_approval_to_carrier FROM fct_orders WHERE is_lifecycle_valid
    UNION ALL SELECT is_late, 'carrier_to_customer_d', days_carrier_to_customer FROM fct_orders WHERE is_lifecycle_valid
    UNION ALL SELECT is_late, 'promised_d', days_purchase_to_estimate FROM fct_orders WHERE is_lifecycle_valid
),
ranked AS (
    SELECT outcome, metric, val,
           ROW_NUMBER() OVER (PARTITION BY outcome, metric ORDER BY val) - 1 AS i,
           COUNT(*) OVER (PARTITION BY outcome, metric) AS n
    FROM v
),
medians AS (
    SELECT outcome, metric,
           SUM(CASE WHEN i = CAST(0.5 * (n - 1) AS INTEGER) THEN val * (1 - (0.5 * (n - 1) - CAST(0.5 * (n - 1) AS INTEGER)))
                    WHEN i = CAST(0.5 * (n - 1) AS INTEGER) + 1 THEN val * (0.5 * (n - 1) - CAST(0.5 * (n - 1) AS INTEGER))
                    ELSE 0 END) AS median
    FROM ranked GROUP BY outcome, metric
),
counts AS (       -- order grain: one row per outcome, computed apart from the medians
    SELECT is_late, COUNT(*) AS n, AVG(is_carrier_handoff_late) AS handoff_late
    FROM fct_orders WHERE is_lifecycle_valid GROUP BY is_late
)
SELECT CASE WHEN c.is_late THEN 'late' ELSE 'on time' END AS delivery_outcome,
       c.n                                                 AS orders_with_valid_lifecycle,
       ROUND((SELECT median FROM medians m WHERE m.outcome = c.is_late AND m.metric = 'approval_h'), 1)            AS median_hours_to_approval,
       ROUND((SELECT median FROM medians m WHERE m.outcome = c.is_late AND m.metric = 'to_carrier_d'), 1)          AS median_days_to_carrier,
       ROUND((SELECT median FROM medians m WHERE m.outcome = c.is_late AND m.metric = 'carrier_to_customer_d'), 1) AS median_days_carrier_to_customer,
       ROUND((SELECT median FROM medians m WHERE m.outcome = c.is_late AND m.metric = 'promised_d'), 1)            AS median_days_promised,
       ROUND(100.0 * c.handoff_late, 1)                    AS pct_handed_to_carrier_after_seller_deadline
FROM counts c
ORDER BY delivery_outcome DESC;

-- =============================================================================
-- Q6. What share of orders are canceled or unavailable?
-- Grain: order. Denominator: ALL orders placed (every status).
-- Category breakdown is limited: 603 of 609 'unavailable' orders and 164 of
-- 625 'canceled' orders have NO order items, so their category is unknown.
-- =============================================================================
-- @result: Q6a Order status distribution (all orders)
SELECT order_status,
       status_group,
       COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders,
       COUNT(*) FILTER (WHERE NOT has_items) AS orders_without_items
FROM fct_orders
GROUP BY order_status, status_group
ORDER BY orders DESC;

-- @result: Q6b Canceled and unavailable share by purchase month
SELECT strftime('%Y-%m', purchase_month) AS purchase_month,
       COUNT(*) AS orders_placed,
       COUNT(*) FILTER (WHERE order_status = 'canceled')    AS canceled,
       COUNT(*) FILTER (WHERE order_status = 'unavailable') AS unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_status IN ('canceled', 'unavailable')) / COUNT(*), 2)
           AS canceled_or_unavailable_pct
FROM fct_orders
WHERE in_trend_window
GROUP BY purchase_month
ORDER BY purchase_month;

-- Only orders with items can be assigned a category; denominator = orders with
-- items in that category (bridge grain). Categories >= 1,000 orders shown.
-- @result: Q6c Canceled share by category (orders with items only, >= 1,000 orders)
SELECT oc.category,
       COUNT(*) AS orders_with_items,
       COUNT(*) FILTER (WHERE o.order_status = 'canceled')    AS canceled,
       COUNT(*) FILTER (WHERE o.order_status = 'unavailable') AS unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.order_status IN ('canceled', 'unavailable')) / COUNT(*), 2)
           AS canceled_or_unavailable_pct
FROM order_categories oc
JOIN fct_orders o USING (order_id)
GROUP BY oc.category
HAVING COUNT(*) >= 1000
ORDER BY 1.0 * COUNT(*) FILTER (WHERE o.order_status IN ('canceled', 'unavailable')) / COUNT(*) DESC, oc.category
LIMIT 15;

-- =============================================================================
-- Q7. Which regions contribute the largest order volume and order value?
-- Grain: order. Volume = all orders placed. Value = items + freight (BRL) for
-- delivered orders only. Order value is gross merchandise value, not profit.
-- =============================================================================
-- @result: Q7a Order volume and order value by customer region
SELECT customer_region,
       COUNT(*)                                                    AS orders_placed,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_orders,
       COUNT(*) FILTER (WHERE status_group = 'delivered')         AS delivered_orders,
       ROUND(SUM(order_value_brl) FILTER (WHERE status_group = 'delivered'), 0) AS delivered_order_value_brl,
       ROUND(100.0 * SUM(order_value_brl) FILTER (WHERE status_group = 'delivered')
             / SUM(SUM(order_value_brl) FILTER (WHERE status_group = 'delivered')) OVER (), 1) AS pct_of_value,
       ROUND(AVG(order_value_brl) FILTER (WHERE status_group = 'delivered'), 2) AS avg_order_value_brl,
       ROUND(AVG(freight_brl / NULLIF(order_value_brl, 0)) FILTER (WHERE status_group = 'delivered') * 100, 1)
           AS avg_freight_share_of_order_pct
FROM fct_orders
GROUP BY customer_region
ORDER BY delivered_order_value_brl DESC;

-- @result: Q7b Top 10 customer states by delivered order value
SELECT customer_state,
       customer_region,
       COUNT(*)                                                   AS orders_placed,
       COUNT(*) FILTER (WHERE status_group = 'delivered')        AS delivered_orders,
       ROUND(SUM(order_value_brl) FILTER (WHERE status_group = 'delivered'), 0) AS delivered_order_value_brl,
       ROUND(100.0 * SUM(order_value_brl) FILTER (WHERE status_group = 'delivered')
             / SUM(SUM(order_value_brl) FILTER (WHERE status_group = 'delivered')) OVER (), 1) AS pct_of_value,
       ROUND(AVG(order_value_brl) FILTER (WHERE status_group = 'delivered'), 2) AS avg_order_value_brl
FROM fct_orders
GROUP BY customer_state, customer_region
ORDER BY delivered_order_value_brl DESC
LIMIT 10;

-- =============================================================================
-- Q8. Which payment methods and installment patterns are most common, and how
--     do they vary with order value?
-- Payment-record grain for method mix; order grain for value comparisons
-- (main_payment_type = payment record with the largest value; ties broken by
-- the lowest payment_sequential).
-- =============================================================================
-- @result: Q8a Payment method mix (payment-record grain and order grain)
WITH by_record AS (
    SELECT payment_type, COUNT(*) AS payment_records, SUM(payment_value_brl) AS paid_brl
    FROM fct_payments GROUP BY 1
), by_order AS (
    SELECT main_payment_type AS payment_type, COUNT(*) AS orders_main_method
    FROM fct_orders WHERE main_payment_type IS NOT NULL GROUP BY 1
)
SELECT r.payment_type,
       r.payment_records,
       ROUND(100.0 * r.payment_records / SUM(r.payment_records) OVER (), 1) AS pct_of_records,
       COALESCE(o.orders_main_method, 0) AS orders_as_main_method,
       ROUND(100.0 * COALESCE(o.orders_main_method, 0) / SUM(COALESCE(o.orders_main_method, 0)) OVER (), 1) AS pct_of_orders,
       ROUND(r.paid_brl, 0) AS paid_brl,
       ROUND(100.0 * r.paid_brl / SUM(r.paid_brl) OVER (), 1) AS pct_of_paid_value
FROM by_record r LEFT JOIN by_order o USING (payment_type)
ORDER BY r.payment_records DESC;

-- @result: Q8b Credit-card installment distribution (payment-record grain)
WITH cc AS (
    SELECT CASE WHEN payment_installments <= 1 THEN '1 (single payment)'
                WHEN payment_installments <= 3 THEN '2-3'
                WHEN payment_installments <= 6 THEN '4-6'
                WHEN payment_installments <= 10 THEN '7-10'
                ELSE '11+' END AS installments,
           payment_installments, payment_value_brl
    FROM fct_payments
    WHERE payment_type = 'credit_card'
),
ranked AS (
    SELECT installments, payment_value_brl AS val,
           ROW_NUMBER() OVER (PARTITION BY installments ORDER BY payment_value_brl) - 1 AS i,
           COUNT(*) OVER (PARTITION BY installments) AS n
    FROM cc
),
medians AS (
    SELECT installments,
           SUM(CASE WHEN i = CAST(0.5 * (n - 1) AS INTEGER) THEN val * (1 - (0.5 * (n - 1) - CAST(0.5 * (n - 1) AS INTEGER)))
                    WHEN i = CAST(0.5 * (n - 1) AS INTEGER) + 1 THEN val * (0.5 * (n - 1) - CAST(0.5 * (n - 1) AS INTEGER))
                    ELSE 0 END) AS median
    FROM ranked GROUP BY installments
)
SELECT cc.installments,
       COUNT(*) AS credit_card_payments,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_credit_card_payments,
       ROUND(MAX(m.median), 2) AS median_payment_brl,
       ROUND(AVG(cc.payment_value_brl), 2) AS avg_payment_brl
FROM cc JOIN medians m USING (installments)
GROUP BY cc.installments
ORDER BY MIN(cc.payment_installments);

-- Order-value bands are payment-value quintiles over orders with a payment.
-- @result: Q8c Payment method and installments by order value band (order grain)
WITH banded AS (
    SELECT *, NTILE(5) OVER (ORDER BY payment_value_brl) AS value_quintile
    FROM fct_orders
    WHERE payment_value_brl IS NOT NULL
)
SELECT value_quintile,
       ROUND(MIN(payment_value_brl), 2)  AS min_order_value_brl,
       ROUND(MAX(payment_value_brl), 2)  AS max_order_value_brl,
       COUNT(*)                          AS orders,
       ROUND(100.0 * AVG(main_payment_type = 'credit_card'), 1) AS pct_credit_card,
       ROUND(100.0 * AVG(main_payment_type = 'boleto'), 1)      AS pct_boleto,
       ROUND(100.0 * AVG(main_payment_type IN ('voucher', 'debit_card', 'not_defined')), 1) AS pct_other,
       ROUND(AVG(max_installments) FILTER (WHERE main_payment_type = 'credit_card'), 1) AS avg_installments_credit_card,
       ROUND(100.0 * AVG(max_installments >= 6) FILTER (WHERE main_payment_type = 'credit_card'), 1)
           AS pct_credit_card_6plus_installments
FROM banded
GROUP BY value_quintile
ORDER BY value_quintile;

-- =============================================================================
-- Q9. Which operational groups should be prioritised?
-- Priority metric: EXCESS LATE ORDERS = late orders - (delivered orders x
-- marketplace late rate). It is the number of late orders the group would avoid
-- if it performed at the marketplace average, combining rate AND volume.
-- Minimum volume: 300 delivered orders for states, lanes and categories; 100 for sellers.
-- =============================================================================
-- @result: Q9a Priority list - customer states ranked by excess late orders
WITH m AS (SELECT AVG(is_late) AS market_rate FROM fct_orders WHERE is_delivery_kpi_eligible)
SELECT customer_state,
       COUNT(*) AS delivered_orders,
       COUNT(*) FILTER (WHERE is_late) AS late_orders,
       ROUND(100.0 * AVG(is_late), 2) AS late_pct,
       ROUND(COUNT(*) FILTER (WHERE is_late) - COUNT(*) * MAX(m.market_rate), 0) AS excess_late_orders,
       ROUND(AVG(review_score), 2) AS avg_review_score
FROM fct_orders CROSS JOIN m
WHERE is_delivery_kpi_eligible
GROUP BY customer_state
HAVING COUNT(*) >= 300
ORDER BY COUNT(*) FILTER (WHERE is_late) - COUNT(*) * MAX(m.market_rate) DESC, customer_state   -- unrounded
LIMIT 10;

-- Lane = seller state -> customer state. Grain: one row per (order, lane), so an
-- order shipped by two sellers from the same state counts once in that lane
-- (same definition as the Power BI 'Lane' column).
-- @result: Q9b Priority list - shipping lanes (seller state -> customer state)
WITH m AS (SELECT AVG(is_late) AS market_rate FROM fct_orders WHERE is_delivery_kpi_eligible),
lane_orders AS (
    SELECT DISTINCT o.order_id, s.seller_state || ' -> ' || o.customer_state AS lane, o.is_late, o.days_carrier_to_customer
    FROM order_sellers os
    JOIN fct_orders o USING (order_id)
    JOIN dim_seller s USING (seller_id)
    WHERE o.is_delivery_kpi_eligible
),
ranked AS (
    SELECT lane, days_carrier_to_customer AS val,
           ROW_NUMBER() OVER (PARTITION BY lane ORDER BY days_carrier_to_customer) - 1 AS i,
           COUNT(*) OVER (PARTITION BY lane) AS n
    FROM lane_orders WHERE days_carrier_to_customer IS NOT NULL
),
medians AS (
    SELECT lane,
           SUM(CASE WHEN i = CAST(0.5 * (n - 1) AS INTEGER) THEN val * (1 - (0.5 * (n - 1) - CAST(0.5 * (n - 1) AS INTEGER)))
                    WHEN i = CAST(0.5 * (n - 1) AS INTEGER) + 1 THEN val * (0.5 * (n - 1) - CAST(0.5 * (n - 1) AS INTEGER))
                    ELSE 0 END) AS median
    FROM ranked GROUP BY lane
)
SELECT l.lane,
       COUNT(*) AS delivered_orders,
       COUNT(*) FILTER (WHERE l.is_late) AS late_orders,
       ROUND(100.0 * AVG(l.is_late), 2) AS late_pct,
       ROUND(COUNT(*) FILTER (WHERE l.is_late) - COUNT(*) * MAX(m.market_rate), 0) AS excess_late_orders,
       ROUND(MAX(md.median), 1) AS median_days_carrier_to_customer
FROM lane_orders l
CROSS JOIN m
LEFT JOIN medians md USING (lane)
GROUP BY l.lane
HAVING COUNT(*) >= 300
ORDER BY COUNT(*) FILTER (WHERE l.is_late) - COUNT(*) * MAX(m.market_rate) DESC, l.lane   -- unrounded
LIMIT 10;

-- @result: Q9c Priority list - categories ranked by excess late orders
WITH m AS (SELECT AVG(is_late) AS market_rate FROM fct_orders WHERE is_delivery_kpi_eligible)
SELECT oc.category,
       COUNT(*) AS delivered_orders,
       COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
       ROUND(100.0 * AVG(o.is_late), 2) AS late_pct,
       ROUND(COUNT(*) FILTER (WHERE o.is_late) - COUNT(*) * MAX(m.market_rate), 0) AS excess_late_orders
FROM order_categories oc
JOIN fct_orders o USING (order_id)
CROSS JOIN m
WHERE o.is_delivery_kpi_eligible
GROUP BY oc.category
HAVING COUNT(*) >= 300
ORDER BY COUNT(*) FILTER (WHERE o.is_late) - COUNT(*) * MAX(m.market_rate) DESC, oc.category   -- unrounded
LIMIT 10;

-- @result: Q9d Priority list - sellers ranked by excess late orders (>= 100 delivered orders)
WITH m AS (SELECT AVG(is_late) AS market_rate FROM fct_orders WHERE is_delivery_kpi_eligible)
SELECT os.seller_id,
       MAX(s.seller_state) AS seller_state,
       COUNT(*) AS delivered_orders,
       COUNT(*) FILTER (WHERE o.is_late) AS late_orders,
       ROUND(100.0 * AVG(o.is_late), 2) AS late_pct,
       ROUND(COUNT(*) FILTER (WHERE o.is_late) - COUNT(*) * MAX(m.market_rate), 0) AS excess_late_orders,
       ROUND(100.0 * AVG(o.is_carrier_handoff_late), 1) AS carrier_handoff_late_pct,
       ROUND(AVG(o.review_score), 2) AS avg_review_score
FROM order_sellers os
JOIN fct_orders o USING (order_id)
JOIN dim_seller s USING (seller_id)
CROSS JOIN m
WHERE o.is_delivery_kpi_eligible
GROUP BY os.seller_id
HAVING COUNT(*) >= 100
ORDER BY COUNT(*) FILTER (WHERE o.is_late) - COUNT(*) * MAX(m.market_rate) DESC, os.seller_id   -- unrounded
LIMIT 15;

-- How concentrated is the problem? Share of all excess late orders captured by
-- the top-N positive-excess sellers (>= 100 orders).
-- @result: Q9e Concentration of excess late orders among sellers (>= 100 delivered orders)
WITH m AS (SELECT AVG(is_late) AS market_rate FROM fct_orders WHERE is_delivery_kpi_eligible),
seller_excess AS (
    SELECT os.seller_id,
           COUNT(*) FILTER (WHERE o.is_late) - COUNT(*) * MAX(m.market_rate) AS excess
    FROM order_sellers os
    JOIN fct_orders o USING (order_id)
    CROSS JOIN m
    WHERE o.is_delivery_kpi_eligible
    GROUP BY os.seller_id
    HAVING COUNT(*) >= 100
),
ranked AS (
    SELECT excess, ROW_NUMBER() OVER (ORDER BY excess DESC) AS rnk,
           SUM(excess) OVER (ORDER BY excess DESC ROWS UNBOUNDED PRECEDING) AS cum_excess
    FROM seller_excess WHERE excess > 0
),
top_ns(top_n) AS (VALUES (10), (25), (50))
SELECT t.top_n,
       ROUND(MAX(r.cum_excess) FILTER (WHERE r.rnk <= t.top_n), 0) AS excess_late_orders_top_n,
       ROUND(MAX(r.cum_excess), 0) AS excess_late_orders_all_positive_sellers,
       COUNT(*) AS sellers_with_positive_excess,
       ROUND(100.0 * MAX(r.cum_excess) FILTER (WHERE r.rnk <= t.top_n) / MAX(r.cum_excess), 1) AS pct_captured
FROM ranked r CROSS JOIN top_ns t
GROUP BY t.top_n
ORDER BY t.top_n;
