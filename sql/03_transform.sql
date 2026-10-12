-- =============================================================================
-- 03_transform.sql   (SQLite)
-- Purpose : Build the analysis-ready star schema. Raw tables are never
--           modified; every cleaning rule is applied here and documented in
--           docs/methodology.md.
--
-- Tables built (grain in brackets)
--   dim_state          [1 row per Brazilian state (UF)]
--   dim_date           [1 row per calendar date]
--   dim_customer       [1 row per customer_id]
--   dim_seller         [1 row per seller_id]
--   dim_product        [1 row per product_id]
--   stg_order_review   [1 row per order_id that has a review]
--   fct_orders         [1 row per order_id]          <- main fact
--   fct_order_items    [1 row per (order_id, order_item_id)]
--   fct_payments       [1 row per (order_id, payment_sequential)]
--   order_sellers      [1 row per (order_id, seller_id)]   bridge
--   order_categories   [1 row per (order_id, category)]    bridge
--
-- Key rule: one-to-many tables (items, payments, reviews) are aggregated to
-- the order grain BEFORE being joined to orders, so no order is double counted.
--
-- SQLite notes
--   * Flags are INTEGER 1/0 (NULL = not applicable).
--   * Durations use unixepoch() differences = whole seconds, then / 86400.0.
--   * Timestamps are ISO text, so '<' and '>' compare them chronologically.
-- =============================================================================

DROP TABLE IF EXISTS dim_state;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS stg_order_review;
DROP TABLE IF EXISTS fct_orders;
DROP TABLE IF EXISTS fct_order_items;
DROP TABLE IF EXISTS fct_payments;
DROP TABLE IF EXISTS order_sellers;
DROP TABLE IF EXISTS order_categories;

-- -----------------------------------------------------------------------------
-- dim_state: Brazilian states mapped to the five official IBGE macro-regions.
-- (Reference data typed in here; not part of the Olist files.)
-- -----------------------------------------------------------------------------
CREATE TABLE dim_state (
    state_code  TEXT PRIMARY KEY,
    state_name  TEXT NOT NULL,
    region      TEXT NOT NULL
);
INSERT INTO dim_state (state_code, state_name, region) VALUES
    ('AC','Acre','North'), ('AP','Amapá','North'), ('AM','Amazonas','North'),
    ('PA','Pará','North'), ('RO','Rondônia','North'), ('RR','Roraima','North'),
    ('TO','Tocantins','North'),
    ('AL','Alagoas','Northeast'), ('BA','Bahia','Northeast'), ('CE','Ceará','Northeast'),
    ('MA','Maranhão','Northeast'), ('PB','Paraíba','Northeast'), ('PE','Pernambuco','Northeast'),
    ('PI','Piauí','Northeast'), ('RN','Rio Grande do Norte','Northeast'), ('SE','Sergipe','Northeast'),
    ('DF','Distrito Federal','Center-West'), ('GO','Goiás','Center-West'),
    ('MT','Mato Grosso','Center-West'), ('MS','Mato Grosso do Sul','Center-West'),
    ('ES','Espírito Santo','Southeast'), ('MG','Minas Gerais','Southeast'),
    ('RJ','Rio de Janeiro','Southeast'), ('SP','São Paulo','Southeast'),
    ('PR','Paraná','South'), ('RS','Rio Grande do Sul','South'), ('SC','Santa Catarina','South');

-- -----------------------------------------------------------------------------
-- dim_date: continuous calendar covering every timestamp in the data.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_date AS
WITH RECURSIVE days(d) AS (
    SELECT '2016-09-01'
    UNION ALL
    SELECT date(d, '+1 day') FROM days WHERE d < '2018-12-31'
)
SELECT
    d                                                         AS date,
    CAST(strftime('%Y', d) AS INTEGER)                        AS year,
    (CAST(strftime('%m', d) AS INTEGER) + 2) / 3              AS quarter,
    CAST(strftime('%m', d) AS INTEGER)                        AS month,
    strftime('%Y-%m', d)                                      AS year_month,
    strftime('%Y-%m-01', d)                                   AS month_start,
    strftime('%Y', d) || '-Q' || ((CAST(strftime('%m', d) AS INTEGER) + 2) / 3) AS year_quarter,
    (CAST(strftime('%w', d) AS INTEGER) + 6) % 7 + 1          AS iso_day_of_week,   -- 1 = Monday
    CASE strftime('%w', d) WHEN '0' THEN 'Sun' WHEN '1' THEN 'Mon' WHEN '2' THEN 'Tue'
         WHEN '3' THEN 'Wed' WHEN '4' THEN 'Thu' WHEN '5' THEN 'Fri' ELSE 'Sat' END AS day_name,
    -- Months with complete, representative data (see 02_load_and_validate.sql)
    d >= '2017-01-01' AND d < '2018-09-01'                    AS in_trend_window
FROM days;

-- -----------------------------------------------------------------------------
-- Dimensions
-- -----------------------------------------------------------------------------
CREATE TABLE dim_customer AS
SELECT c.customer_id,
       c.customer_unique_id,
       c.customer_zip_code_prefix,
       c.customer_city,
       c.customer_state,
       s.state_name AS customer_state_name,
       s.region     AS customer_region
FROM raw_customers c
LEFT JOIN dim_state s ON s.state_code = c.customer_state;

CREATE TABLE dim_seller AS
SELECT sl.seller_id,
       sl.seller_zip_code_prefix,
       sl.seller_city,
       sl.seller_state,
       s.state_name AS seller_state_name,
       s.region     AS seller_region
FROM raw_sellers sl
LEFT JOIN dim_state s ON s.state_code = sl.seller_state;

-- Category cleaning:
--   * NULL category              -> 'unknown'   (610 products)
--   * 2 categories have no row in the translation file; translated manually
--     and flagged in category_translation_source.
CREATE TABLE dim_product AS
SELECT p.product_id,
       COALESCE(p.product_category_name, 'unknown') AS category_pt,
       CASE
           WHEN p.product_category_name IS NULL THEN 'unknown'
           WHEN t.product_category_name_english IS NOT NULL THEN t.product_category_name_english
           WHEN p.product_category_name = 'pc_gamer' THEN 'pc_gamer'
           WHEN p.product_category_name = 'portateis_cozinha_e_preparadores_de_alimentos'
                THEN 'portable_kitchen_and_food_preparers'
           ELSE p.product_category_name
       END AS category,
       CASE
           WHEN p.product_category_name IS NULL THEN 'missing in source'
           WHEN t.product_category_name_english IS NOT NULL THEN 'olist translation file'
           ELSE 'manual translation (not in source file)'
       END AS category_translation_source,
       p.product_photos_qty,
       p.product_weight_g,
       p.product_length_cm,
       p.product_height_cm,
       p.product_width_cm
FROM raw_products p
LEFT JOIN raw_product_category_name_translation t ON t.product_category_name = p.product_category_name;

-- -----------------------------------------------------------------------------
-- stg_order_review: collapse reviews to ONE row per order.
-- 547 orders have 2-3 reviews. Rule: keep the most recently answered review
-- (ties broken by creation date, then review_id) so each order has one score.
-- review_count keeps the original number for transparency.
-- -----------------------------------------------------------------------------
CREATE TABLE stg_order_review AS
SELECT order_id, review_id, review_score, review_creation_date, review_answer_timestamp,
       review_count, has_comment
FROM (
    SELECT r.*,
           COUNT(*) OVER (PARTITION BY order_id) AS review_count,
           (review_comment_message IS NOT NULL AND TRIM(review_comment_message) <> '') AS has_comment,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC, review_creation_date DESC, review_id) AS rn
    FROM raw_order_reviews r
)
WHERE rn = 1;

-- -----------------------------------------------------------------------------
-- fct_orders: ONE ROW PER ORDER. All 99,441 orders are kept; flags decide
-- which orders enter each KPI (no rows are deleted).
-- -----------------------------------------------------------------------------
CREATE TABLE fct_orders AS
WITH items_per_order AS (          -- order_items aggregated to order grain
    SELECT i.order_id,
           COUNT(*)                         AS item_count,
           COUNT(DISTINCT i.seller_id)      AS seller_count,
           COUNT(DISTINCT p.category)       AS category_count,
           SUM(i.price)                     AS items_price_brl,
           SUM(i.freight_value)             AS freight_brl,
           MAX(i.shipping_limit_date)       AS latest_shipping_limit_date
    FROM raw_order_items i
    JOIN dim_product p ON p.product_id = i.product_id
    GROUP BY i.order_id
),
payment_ranked AS (                -- main method = largest payment record
    SELECT order_id, payment_type,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY payment_value DESC, payment_sequential) AS rn
    FROM raw_order_payments
),
payments_per_order AS (            -- order_payments aggregated to order grain
    SELECT p.order_id,
           COUNT(*)                                  AS payment_count,
           SUM(p.payment_value)                      AS payment_value_brl,
           MAX(pr.payment_type)                      AS main_payment_type,
           MAX(p.payment_installments)               AS max_installments,
           MAX(p.payment_type = 'voucher')           AS used_voucher
    FROM raw_order_payments p
    JOIN payment_ranked pr ON pr.order_id = p.order_id AND pr.rn = 1
    GROUP BY p.order_id
),
base AS (
    SELECT o.*,
           c.customer_unique_id, c.customer_state, c.customer_region,
           CASE
               WHEN o.order_status = 'delivered'   THEN 'delivered'
               WHEN o.order_status = 'canceled'    THEN 'canceled'
               WHEN o.order_status = 'unavailable' THEN 'unavailable'
               ELSE 'in progress'   -- shipped, invoiced, processing, created, approved
           END AS status_group,
           -- Delivery KPIs use delivered orders with a delivery date only.
           CASE
               WHEN o.order_status <> 'delivered' THEN 'excluded: status is ' || o.order_status
               WHEN o.order_delivered_customer_date IS NULL THEN 'excluded: delivered status but no delivery date'
               WHEN o.order_delivered_customer_date < o.order_purchase_timestamp THEN 'excluded: delivery before purchase'
               ELSE 'included'
           END AS delivery_kpi_status
    FROM raw_orders o
    LEFT JOIN dim_customer c ON c.customer_id = o.customer_id
)
SELECT
    b.order_id,
    b.customer_id,
    b.customer_unique_id,
    b.customer_state,
    b.customer_region,
    b.order_status,
    b.status_group,
    b.order_purchase_timestamp,
    b.order_approved_at,
    b.order_delivered_carrier_date,
    b.order_delivered_customer_date,
    b.order_estimated_delivery_date,
    date(b.order_purchase_timestamp)                              AS purchase_date,
    strftime('%Y-%m-01', b.order_purchase_timestamp)              AS purchase_month,
    (b.order_purchase_timestamp >= '2017-01-01'
        AND b.order_purchase_timestamp < '2018-09-01')            AS in_trend_window,

    -- ---- order contents (from items, already at order grain) --------------
    COALESCE(i.item_count, 0)              AS item_count,
    COALESCE(i.seller_count, 0)            AS seller_count,
    COALESCE(i.category_count, 0)          AS category_count,
    (i.item_count IS NOT NULL)             AS has_items,
    ROUND(i.items_price_brl, 2)            AS items_price_brl,
    ROUND(i.freight_brl, 2)                AS freight_brl,
    ROUND(i.items_price_brl + i.freight_brl, 2) AS order_value_brl,   -- goods + freight, NOT profit
    i.latest_shipping_limit_date,

    -- ---- payments (already at order grain) ---------------------------------
    COALESCE(p.payment_count, 0)           AS payment_count,
    ROUND(p.payment_value_brl, 2)          AS payment_value_brl,
    p.main_payment_type,
    p.max_installments,
    COALESCE(p.used_voucher, 0)            AS used_voucher,

    -- ---- delivery KPIs -----------------------------------------------------
    b.delivery_kpi_status,
    (b.delivery_kpi_status = 'included')   AS is_delivery_kpi_eligible,
    -- PRIMARY late definition: delivered on a later CALENDAR DATE than the
    -- estimate. The estimate is stored as midnight (no time of day), so a pure
    -- timestamp comparison would label same-day deliveries as late.
    CASE WHEN b.delivery_kpi_status = 'included'
         THEN date(b.order_delivered_customer_date) > date(b.order_estimated_delivery_date)
    END AS is_late,
    -- SENSITIVITY definition: literal timestamp comparison (delivered > estimate).
    CASE WHEN b.delivery_kpi_status = 'included'
         THEN b.order_delivered_customer_date > b.order_estimated_delivery_date
    END AS is_late_timestamp_rule,
    -- Positive = days after the estimate, negative = days early.
    CASE WHEN b.delivery_kpi_status = 'included'
         THEN (unixepoch(date(b.order_delivered_customer_date)) - unixepoch(date(b.order_estimated_delivery_date))) / 86400
    END AS days_vs_estimate,
    CASE WHEN b.delivery_kpi_status = 'included'
         THEN (unixepoch(b.order_delivered_customer_date) - unixepoch(b.order_purchase_timestamp)) / 86400.0
    END AS days_purchase_to_delivery,
    (unixepoch(b.order_estimated_delivery_date) - unixepoch(b.order_purchase_timestamp)) / 86400.0
        AS days_purchase_to_estimate,

    -- ---- lifecycle stages (delivered orders only; each stage is NULL when
    --      either timestamp is missing or the pair is out of sequence) -------
    CASE WHEN b.delivery_kpi_status = 'included'
          AND b.order_approved_at >= b.order_purchase_timestamp
         THEN (unixepoch(b.order_approved_at) - unixepoch(b.order_purchase_timestamp)) / 3600.0
    END AS hours_purchase_to_approval,
    CASE WHEN b.delivery_kpi_status = 'included'
          AND b.order_delivered_carrier_date >= b.order_approved_at
         THEN (unixepoch(b.order_delivered_carrier_date) - unixepoch(b.order_approved_at)) / 86400.0
    END AS days_approval_to_carrier,
    CASE WHEN b.delivery_kpi_status = 'included'
          AND b.order_delivered_customer_date >= b.order_delivered_carrier_date
         THEN (unixepoch(b.order_delivered_customer_date) - unixepoch(b.order_delivered_carrier_date)) / 86400.0
    END AS days_carrier_to_customer,
    COALESCE(b.delivery_kpi_status = 'included'
        AND b.order_approved_at >= b.order_purchase_timestamp
        AND b.order_delivered_carrier_date >= b.order_approved_at
        AND b.order_delivered_customer_date >= b.order_delivered_carrier_date, 0) AS is_lifecycle_valid,
    -- Seller handed the parcel to the carrier after the seller shipping deadline
    -- (latest deadline across the order's items). Seller-controllable signal.
    CASE WHEN b.delivery_kpi_status = 'included' AND b.order_delivered_carrier_date IS NOT NULL
         THEN b.order_delivered_carrier_date > i.latest_shipping_limit_date
    END AS is_carrier_handoff_late,

    -- ---- review (already one row per order) --------------------------------
    r.review_score,
    r.review_count,
    (r.review_score IS NOT NULL)           AS has_review,
    r.has_comment                          AS review_has_comment,
    r.review_creation_date,
    CASE WHEN r.review_score IS NOT NULL AND b.order_delivered_customer_date IS NOT NULL
         THEN date(r.review_creation_date) < date(b.order_delivered_customer_date)
    END AS review_created_before_delivery
FROM base b
LEFT JOIN items_per_order    i ON i.order_id = b.order_id
LEFT JOIN payments_per_order p ON p.order_id = b.order_id
LEFT JOIN stg_order_review   r ON r.order_id = b.order_id;

CREATE UNIQUE INDEX ix_fct_orders_order_id ON fct_orders (order_id);

-- -----------------------------------------------------------------------------
-- fct_order_items: ONE ROW PER ORDER ITEM. Revenue-type sums belong here;
-- order counts from this table must use COUNT(DISTINCT order_id).
-- -----------------------------------------------------------------------------
CREATE TABLE fct_order_items AS
SELECT i.order_id,
       i.order_item_id,
       i.product_id,
       i.seller_id,
       o.customer_id,
       o.purchase_date,
       i.shipping_limit_date,
       i.price                             AS price_brl,
       i.freight_value                     AS freight_brl,
       ROUND(i.price + i.freight_value, 2) AS item_value_brl
FROM raw_order_items i
JOIN fct_orders o ON o.order_id = i.order_id;   -- many-to-one: cannot add rows

CREATE INDEX ix_fct_order_items_order_id ON fct_order_items (order_id);

-- fct_payments: ONE ROW PER PAYMENT RECORD.
CREATE TABLE fct_payments AS
SELECT order_id,
       payment_sequential,
       payment_type,
       payment_installments,
       payment_value AS payment_value_brl
FROM raw_order_payments;

-- -----------------------------------------------------------------------------
-- Bridges for seller- and category-level delivery metrics.
-- Delivery dates exist only at ORDER level, so an order shipped by two sellers
-- counts once for each seller (1.3% of orders have more than one seller).
-- -----------------------------------------------------------------------------
CREATE TABLE order_sellers AS
SELECT order_id, seller_id,
       COUNT(*)                      AS items,
       ROUND(SUM(item_value_brl), 2) AS seller_items_value_brl
FROM fct_order_items
GROUP BY order_id, seller_id;

CREATE TABLE order_categories AS
SELECT i.order_id, p.category,
       COUNT(*)                        AS items,
       ROUND(SUM(i.item_value_brl), 2) AS category_items_value_brl
FROM fct_order_items i
JOIN dim_product p ON p.product_id = i.product_id
GROUP BY i.order_id, p.category;

CREATE INDEX ix_order_sellers_order_id ON order_sellers (order_id);
CREATE INDEX ix_order_categories_order_id ON order_categories (order_id);

-- =============================================================================
-- POST-TRANSFORM VALIDATION (join cardinality and record counts)
-- =============================================================================
-- @check: Row counts are preserved through every join
SELECT test, before_rows, after_rows, before_rows = after_rows AS passed
FROM (
    SELECT 'raw_orders -> fct_orders' AS test,
           (SELECT COUNT(*) FROM raw_orders) AS before_rows, (SELECT COUNT(*) FROM fct_orders) AS after_rows
    UNION ALL SELECT 'fct_orders distinct order_id',
           (SELECT COUNT(*) FROM fct_orders), (SELECT COUNT(DISTINCT order_id) FROM fct_orders)
    UNION ALL SELECT 'raw_order_items -> fct_order_items',
           (SELECT COUNT(*) FROM raw_order_items), (SELECT COUNT(*) FROM fct_order_items)
    UNION ALL SELECT 'raw_order_payments -> fct_payments',
           (SELECT COUNT(*) FROM raw_order_payments), (SELECT COUNT(*) FROM fct_payments)
    UNION ALL SELECT 'raw_customers -> dim_customer',
           (SELECT COUNT(*) FROM raw_customers), (SELECT COUNT(*) FROM dim_customer)
    UNION ALL SELECT 'raw_products -> dim_product',
           (SELECT COUNT(*) FROM raw_products), (SELECT COUNT(*) FROM dim_product)
    UNION ALL SELECT 'raw_sellers -> dim_seller',
           (SELECT COUNT(*) FROM raw_sellers), (SELECT COUNT(*) FROM dim_seller)
    UNION ALL SELECT 'distinct reviewed orders -> stg_order_review',
           (SELECT COUNT(DISTINCT order_id) FROM raw_order_reviews), (SELECT COUNT(*) FROM stg_order_review)
    UNION ALL SELECT 'distinct (order, seller) pairs -> order_sellers',
           (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, seller_id FROM raw_order_items)),
           (SELECT COUNT(*) FROM order_sellers)
);

-- @check: Money totals are preserved after aggregating to order grain
SELECT test, ROUND(source_total, 2) AS source_total, ROUND(model_total, 2) AS model_total,
       ABS(source_total - model_total) < 0.01 AS passed
FROM (
    SELECT 'items price + freight' AS test,
           (SELECT SUM(price + freight_value) FROM raw_order_items) AS source_total,
           (SELECT SUM(order_value_brl) FROM fct_orders)            AS model_total
    UNION ALL SELECT 'payment value',
           (SELECT SUM(payment_value) FROM raw_order_payments),
           (SELECT SUM(payment_value_brl) FROM fct_orders)
    UNION ALL SELECT 'order item count',
           (SELECT COUNT(*) FROM raw_order_items),
           (SELECT SUM(item_count) FROM fct_orders)
);

-- @check: Every customer and seller state maps to a region
SELECT 'customers without region' AS test, COUNT(*) AS rows_unmapped, COUNT(*) = 0 AS passed
FROM dim_customer WHERE customer_region IS NULL
UNION ALL
SELECT 'sellers without region', COUNT(*), COUNT(*) = 0
FROM dim_seller WHERE seller_region IS NULL;

-- @result: KPI inclusion log - rows entering each delivery KPI and why others are excluded
SELECT delivery_kpi_status, COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_all_orders
FROM fct_orders
GROUP BY delivery_kpi_status
ORDER BY orders DESC;

-- @result: Lifecycle stage exclusions among delivery-KPI-eligible orders
SELECT COUNT(*) AS eligible_delivered_orders,
       COUNT(hours_purchase_to_approval) AS valid_purchase_to_approval,
       COUNT(*) - COUNT(hours_purchase_to_approval) AS excluded_purchase_to_approval,
       COUNT(days_approval_to_carrier)   AS valid_approval_to_carrier,
       COUNT(*) - COUNT(days_approval_to_carrier)   AS excluded_approval_to_carrier,
       COUNT(days_carrier_to_customer)   AS valid_carrier_to_customer,
       COUNT(*) - COUNT(days_carrier_to_customer)   AS excluded_carrier_to_customer,
       COUNT(*) FILTER (WHERE is_lifecycle_valid)   AS valid_all_three_stages
FROM fct_orders
WHERE is_delivery_kpi_eligible;

-- @result: Analytics table inventory (grain and row counts)
SELECT 'fct_orders' AS table_name, '1 row per order' AS grain, COUNT(*) AS row_count FROM fct_orders
UNION ALL SELECT 'fct_order_items', '1 row per order item', COUNT(*) FROM fct_order_items
UNION ALL SELECT 'fct_payments', '1 row per payment record', COUNT(*) FROM fct_payments
UNION ALL SELECT 'order_sellers', '1 row per (order, seller)', COUNT(*) FROM order_sellers
UNION ALL SELECT 'order_categories', '1 row per (order, category)', COUNT(*) FROM order_categories
UNION ALL SELECT 'stg_order_review', '1 row per reviewed order', COUNT(*) FROM stg_order_review
UNION ALL SELECT 'dim_customer', '1 row per customer_id', COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_seller', '1 row per seller', COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_product', '1 row per product', COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_state', '1 row per state', COUNT(*) FROM dim_state
UNION ALL SELECT 'dim_date', '1 row per calendar date', COUNT(*) FROM dim_date;
