-- =============================================================================
-- 02_load_and_validate.sql   (SQLite)
-- Purpose : Load the nine raw Olist CSVs into raw_* staging tables, then profile
--           and validate them: row counts, stored types, key uniqueness,
--           foreign-key coverage, missing timestamps, timestamp ordering and
--           status contradictions.
--
-- Conventions used by scripts/build_database.py
--   -- @load:   <table> <- <csv path>  -> SQLite SQL has no COPY command, so the
--                                         runner streams the CSV with Python's csv
--                                         module into the table (empty cell -> NULL,
--                                         header must match the table's columns).
--   -- @result: <title>  -> query output is saved to reports/sql_results/
--   -- @check:  <title>  -> query must return a column `passed` (1/0);
--                           the build stops if any row has passed = 0
-- Paths are relative to the project root.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. LOAD (raw files are read, never modified)
-- -----------------------------------------------------------------------------
-- @load: raw_orders <- data/raw/olist_orders_dataset.csv
-- @load: raw_order_items <- data/raw/olist_order_items_dataset.csv
-- @load: raw_order_payments <- data/raw/olist_order_payments_dataset.csv
-- @load: raw_order_reviews <- data/raw/olist_order_reviews_dataset.csv
-- @load: raw_customers <- data/raw/olist_customers_dataset.csv
-- @load: raw_sellers <- data/raw/olist_sellers_dataset.csv
-- @load: raw_products <- data/raw/olist_products_dataset.csv
-- @load: raw_product_category_name_translation <- data/raw/product_category_name_translation.csv
-- @load: raw_geolocation <- data/raw/olist_geolocation_dataset.csv

-- Lookup indexes on the join keys (they add no rows and change no values).
-- Without them SQLite answers the coverage checks below with nested scans.
CREATE INDEX ix_raw_orders_order_id        ON raw_orders (order_id);
CREATE INDEX ix_raw_orders_customer_id     ON raw_orders (customer_id);
CREATE INDEX ix_raw_order_items_order_id   ON raw_order_items (order_id);
CREATE INDEX ix_raw_order_items_product_id ON raw_order_items (product_id);
CREATE INDEX ix_raw_order_items_seller_id  ON raw_order_items (seller_id);
CREATE INDEX ix_raw_order_payments_order   ON raw_order_payments (order_id);
CREATE INDEX ix_raw_order_reviews_order_id ON raw_order_reviews (order_id);
CREATE INDEX ix_raw_customers_customer_id  ON raw_customers (customer_id);
CREATE INDEX ix_raw_products_product_id    ON raw_products (product_id);
CREATE INDEX ix_raw_sellers_seller_id      ON raw_sellers (seller_id);
CREATE INDEX ix_raw_geolocation_zip        ON raw_geolocation (geolocation_zip_code_prefix);

-- -----------------------------------------------------------------------------
-- 2. ROW COUNTS
-- Expected counts are the published row counts of the Kaggle files (CSV line
-- count minus header; reviews contain multi-line comments so wc -l is higher).
-- -----------------------------------------------------------------------------
-- @check: Raw row counts match the source files
SELECT table_name, actual_rows, expected_rows, actual_rows = expected_rows AS passed
FROM (
    SELECT 'orders' AS table_name, (SELECT COUNT(*) FROM raw_orders) AS actual_rows, 99441 AS expected_rows
    UNION ALL SELECT 'order_items',    (SELECT COUNT(*) FROM raw_order_items),    112650
    UNION ALL SELECT 'order_payments', (SELECT COUNT(*) FROM raw_order_payments), 103886
    UNION ALL SELECT 'order_reviews',  (SELECT COUNT(*) FROM raw_order_reviews),  99224
    UNION ALL SELECT 'customers',      (SELECT COUNT(*) FROM raw_customers),      99441
    UNION ALL SELECT 'sellers',        (SELECT COUNT(*) FROM raw_sellers),        3095
    UNION ALL SELECT 'products',       (SELECT COUNT(*) FROM raw_products),       32951
    UNION ALL SELECT 'category_translation', (SELECT COUNT(*) FROM raw_product_category_name_translation), 71
    UNION ALL SELECT 'geolocation',    (SELECT COUNT(*) FROM raw_geolocation),    1000163
);

-- SQLite is dynamically typed: confirm every value landed with the declared
-- type and every timestamp has the exact 'YYYY-MM-DD HH:MM:SS' shape, so that
-- text comparisons and date functions behave like real timestamps.
-- @check: Stored types and timestamp formats are as declared
WITH ts(table_column, value) AS (
    SELECT 'orders.order_purchase_timestamp', order_purchase_timestamp FROM raw_orders
    UNION ALL SELECT 'orders.order_approved_at', order_approved_at FROM raw_orders
    UNION ALL SELECT 'orders.order_delivered_carrier_date', order_delivered_carrier_date FROM raw_orders
    UNION ALL SELECT 'orders.order_delivered_customer_date', order_delivered_customer_date FROM raw_orders
    UNION ALL SELECT 'orders.order_estimated_delivery_date', order_estimated_delivery_date FROM raw_orders
    UNION ALL SELECT 'order_items.shipping_limit_date', shipping_limit_date FROM raw_order_items
    UNION ALL SELECT 'order_reviews.review_creation_date', review_creation_date FROM raw_order_reviews
    UNION ALL SELECT 'order_reviews.review_answer_timestamp', review_answer_timestamp FROM raw_order_reviews
)
SELECT table_column AS tested,
       COUNT(value) AS non_null_values,
       SUM(value NOT GLOB '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
           OR datetime(value) IS NULL OR datetime(value) <> value) AS bad_values,
       SUM(value NOT GLOB '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
           OR datetime(value) IS NULL OR datetime(value) <> value) = 0 AS passed
FROM ts WHERE value IS NOT NULL
GROUP BY table_column
UNION ALL
SELECT 'numeric columns stored as numbers', COUNT(*),
       SUM(typeof(price) NOT IN ('real', 'integer') OR typeof(freight_value) NOT IN ('real', 'integer')
           OR typeof(order_item_id) <> 'integer'),
       SUM(typeof(price) NOT IN ('real', 'integer') OR typeof(freight_value) NOT IN ('real', 'integer')
           OR typeof(order_item_id) <> 'integer') = 0
FROM raw_order_items
UNION ALL
SELECT 'payment numeric columns stored as numbers', COUNT(*),
       SUM(typeof(payment_value) NOT IN ('real', 'integer') OR typeof(payment_installments) <> 'integer'
           OR typeof(payment_sequential) <> 'integer'),
       SUM(typeof(payment_value) NOT IN ('real', 'integer') OR typeof(payment_installments) <> 'integer'
           OR typeof(payment_sequential) <> 'integer') = 0
FROM raw_order_payments
UNION ALL
SELECT 'review_score stored as integer 1-5', COUNT(*),
       SUM(typeof(review_score) <> 'integer' OR review_score NOT BETWEEN 1 AND 5),
       SUM(typeof(review_score) <> 'integer' OR review_score NOT BETWEEN 1 AND 5) = 0
FROM raw_order_reviews
UNION ALL
SELECT 'zip prefixes kept as 5-character text', COUNT(*),
       SUM(typeof(customer_zip_code_prefix) <> 'text' OR LENGTH(customer_zip_code_prefix) <> 5),
       SUM(typeof(customer_zip_code_prefix) <> 'text' OR LENGTH(customer_zip_code_prefix) <> 5) = 0
FROM raw_customers;

-- -----------------------------------------------------------------------------
-- 3. KEY UNIQUENESS (confirms the grain of each table)
-- -----------------------------------------------------------------------------
-- @check: Candidate primary keys are unique and non-null
SELECT key_tested, total_rows, distinct_keys, null_keys,
       total_rows = distinct_keys AND null_keys = 0 AS passed
FROM (
    SELECT 'orders.order_id' AS key_tested, COUNT(*) AS total_rows, COUNT(DISTINCT order_id) AS distinct_keys,
           COUNT(*) - COUNT(order_id) AS null_keys FROM raw_orders
    UNION ALL SELECT 'customers.customer_id', COUNT(*), COUNT(DISTINCT customer_id), COUNT(*) - COUNT(customer_id) FROM raw_customers
    UNION ALL SELECT 'sellers.seller_id', COUNT(*), COUNT(DISTINCT seller_id), COUNT(*) - COUNT(seller_id) FROM raw_sellers
    UNION ALL SELECT 'products.product_id', COUNT(*), COUNT(DISTINCT product_id), COUNT(*) - COUNT(product_id) FROM raw_products
    UNION ALL SELECT 'order_items.(order_id, order_item_id)', COUNT(*),
           (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, order_item_id FROM raw_order_items)),
           COUNT(*) - COUNT(order_id) FROM raw_order_items
    UNION ALL SELECT 'order_payments.(order_id, payment_sequential)', COUNT(*),
           (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, payment_sequential FROM raw_order_payments)),
           COUNT(*) - COUNT(order_id) FROM raw_order_payments
    UNION ALL SELECT 'order_reviews.(review_id, order_id)', COUNT(*),
           (SELECT COUNT(*) FROM (SELECT DISTINCT review_id, order_id FROM raw_order_reviews)),
           COUNT(*) - COUNT(review_id) FROM raw_order_reviews
    UNION ALL SELECT 'category_translation.product_category_name', COUNT(*), COUNT(DISTINCT product_category_name),
           COUNT(*) - COUNT(product_category_name) FROM raw_product_category_name_translation
);

-- @result: Keys that are NOT unique (documented, handled in 03_transform.sql)
SELECT 'order_reviews.review_id' AS key_tested,
       COUNT(*) AS total_rows,
       COUNT(DISTINCT review_id) AS distinct_values,
       COUNT(*) - COUNT(DISTINCT review_id) AS surplus_rows
FROM raw_order_reviews
UNION ALL
SELECT 'order_reviews.order_id (orders with >1 review)',
       COUNT(*), COUNT(DISTINCT order_id), COUNT(*) - COUNT(DISTINCT order_id)
FROM raw_order_reviews
UNION ALL
SELECT 'geolocation.zip_code_prefix',
       COUNT(*), COUNT(DISTINCT geolocation_zip_code_prefix), COUNT(*) - COUNT(DISTINCT geolocation_zip_code_prefix)
FROM raw_geolocation
UNION ALL
SELECT 'customers.customer_unique_id (repeat customers)',
       COUNT(*), COUNT(DISTINCT customer_unique_id), COUNT(*) - COUNT(DISTINCT customer_unique_id)
FROM raw_customers;

-- -----------------------------------------------------------------------------
-- 4. FOREIGN-KEY COVERAGE
-- -----------------------------------------------------------------------------
-- @check: Child keys always find a parent row (referential integrity)
WITH fk AS (
    SELECT 'orders.customer_id -> customers' AS relationship, COUNT(*) AS child_rows,
           COUNT(*) FILTER (WHERE c.customer_id IS NULL) AS orphan_rows
    FROM raw_orders o LEFT JOIN raw_customers c ON c.customer_id = o.customer_id
    UNION ALL
    SELECT 'order_items.order_id -> orders', COUNT(*), COUNT(*) FILTER (WHERE o.order_id IS NULL)
    FROM raw_order_items i LEFT JOIN raw_orders o ON o.order_id = i.order_id
    UNION ALL
    SELECT 'order_items.product_id -> products', COUNT(*), COUNT(*) FILTER (WHERE p.product_id IS NULL)
    FROM raw_order_items i LEFT JOIN raw_products p ON p.product_id = i.product_id
    UNION ALL
    SELECT 'order_items.seller_id -> sellers', COUNT(*), COUNT(*) FILTER (WHERE s.seller_id IS NULL)
    FROM raw_order_items i LEFT JOIN raw_sellers s ON s.seller_id = i.seller_id
    UNION ALL
    SELECT 'order_payments.order_id -> orders', COUNT(*), COUNT(*) FILTER (WHERE o.order_id IS NULL)
    FROM raw_order_payments p LEFT JOIN raw_orders o ON o.order_id = p.order_id
    UNION ALL
    SELECT 'order_reviews.order_id -> orders', COUNT(*), COUNT(*) FILTER (WHERE o.order_id IS NULL)
    FROM raw_order_reviews r LEFT JOIN raw_orders o ON o.order_id = r.order_id
)
SELECT relationship, child_rows, orphan_rows, orphan_rows = 0 AS passed FROM fk;

-- @result: Parent coverage and soft relationships (gaps are expected and documented)
SELECT 'orders with >= 1 order item' AS coverage_test,
       COUNT(*) AS parent_rows,
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)) AS covered,
       COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM raw_order_items i WHERE i.order_id = o.order_id)) AS not_covered
FROM raw_orders o
UNION ALL
SELECT 'orders with >= 1 payment', COUNT(*),
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM raw_order_payments p WHERE p.order_id = o.order_id)),
       COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM raw_order_payments p WHERE p.order_id = o.order_id))
FROM raw_orders o
UNION ALL
SELECT 'orders with >= 1 review', COUNT(*),
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM raw_order_reviews r WHERE r.order_id = o.order_id)),
       COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM raw_order_reviews r WHERE r.order_id = o.order_id))
FROM raw_orders o
UNION ALL
SELECT 'products with a category name', COUNT(*),
       COUNT(product_category_name), COUNT(*) - COUNT(product_category_name)
FROM raw_products
UNION ALL
SELECT 'distinct product categories with an English translation',
       COUNT(DISTINCT p.product_category_name),
       COUNT(DISTINCT p.product_category_name) FILTER (WHERE t.product_category_name IS NOT NULL),
       COUNT(DISTINCT p.product_category_name) FILTER (WHERE t.product_category_name IS NULL)
FROM raw_products p
LEFT JOIN raw_product_category_name_translation t ON t.product_category_name = p.product_category_name
UNION ALL
SELECT 'customer zip prefixes found in geolocation', COUNT(DISTINCT customer_zip_code_prefix),
       COUNT(DISTINCT customer_zip_code_prefix) FILTER (WHERE customer_zip_code_prefix IN (SELECT geolocation_zip_code_prefix FROM raw_geolocation)),
       COUNT(DISTINCT customer_zip_code_prefix) FILTER (WHERE customer_zip_code_prefix NOT IN (SELECT geolocation_zip_code_prefix FROM raw_geolocation))
FROM raw_customers;

-- @result: Untranslated product categories
SELECT p.product_category_name, COUNT(*) AS products
FROM raw_products p
LEFT JOIN raw_product_category_name_translation t ON t.product_category_name = p.product_category_name
WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL
GROUP BY 1 ORDER BY 1;

-- -----------------------------------------------------------------------------
-- 5. ORDER STATUS x MISSING TIMESTAMPS
-- -----------------------------------------------------------------------------
-- @result: Order status and timestamp completeness
SELECT order_status,
       COUNT(*)                                        AS orders,
       COUNT(*) - COUNT(order_approved_at)             AS missing_approved_at,
       COUNT(*) - COUNT(order_delivered_carrier_date)  AS missing_carrier_date,
       COUNT(*) - COUNT(order_delivered_customer_date) AS missing_customer_delivery_date,
       COUNT(*) - COUNT(order_estimated_delivery_date) AS missing_estimated_date
FROM raw_orders
GROUP BY order_status
ORDER BY orders DESC;

-- @result: Status contradictions
SELECT 'status = delivered but no customer delivery date' AS issue, COUNT(*) AS orders
FROM raw_orders WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL
UNION ALL
SELECT 'status = canceled but has a customer delivery date', COUNT(*)
FROM raw_orders WHERE order_status = 'canceled' AND order_delivered_customer_date IS NOT NULL
UNION ALL
SELECT 'status = delivered but no approval timestamp', COUNT(*)
FROM raw_orders WHERE order_status = 'delivered' AND order_approved_at IS NULL
UNION ALL
SELECT 'status = delivered but no carrier timestamp', COUNT(*)
FROM raw_orders WHERE order_status = 'delivered' AND order_delivered_carrier_date IS NULL;

-- -----------------------------------------------------------------------------
-- 6. TIMESTAMP VALIDITY
-- -----------------------------------------------------------------------------
-- @result: Out-of-sequence timestamps (rows where a later stage precedes an earlier one)
SELECT 'approved_at < purchase_timestamp' AS sequence_violation, COUNT(*) AS orders
FROM raw_orders WHERE order_approved_at < order_purchase_timestamp
UNION ALL SELECT 'carrier_date < approved_at', COUNT(*)
FROM raw_orders WHERE order_delivered_carrier_date < order_approved_at
UNION ALL SELECT 'carrier_date < purchase_timestamp', COUNT(*)
FROM raw_orders WHERE order_delivered_carrier_date < order_purchase_timestamp
UNION ALL SELECT 'customer_delivery < carrier_date', COUNT(*)
FROM raw_orders WHERE order_delivered_customer_date < order_delivered_carrier_date
UNION ALL SELECT 'customer_delivery < purchase_timestamp', COUNT(*)
FROM raw_orders WHERE order_delivered_customer_date < order_purchase_timestamp
UNION ALL SELECT 'estimated_delivery < purchase_timestamp', COUNT(*)
FROM raw_orders WHERE order_estimated_delivery_date < order_purchase_timestamp;

-- The estimated delivery "timestamp" is really a date: every value is at midnight.
-- This drives the late-delivery definition (see 03_transform.sql).
-- @result: Estimated delivery dates carrying a time-of-day component
SELECT COUNT(*) AS orders,
       COUNT(*) FILTER (WHERE time(order_estimated_delivery_date) <> '00:00:00') AS with_non_midnight_time
FROM raw_orders;

-- @result: Purchase date range and partial periods
SELECT MIN(order_purchase_timestamp) AS first_purchase,
       MAX(order_purchase_timestamp) AS last_purchase,
       COUNT(*) FILTER (WHERE order_purchase_timestamp < '2017-01-01')  AS orders_before_2017,
       COUNT(*) FILTER (WHERE order_purchase_timestamp >= '2018-09-01') AS orders_from_sep_2018
FROM raw_orders;

-- -----------------------------------------------------------------------------
-- 7. VALUE / OUTLIER CHECKS
-- Percentiles: SQLite has no MEDIAN/PERCENTILE function, so the continuous
-- (linearly interpolated) percentile is computed with window functions:
--   position = p * (n - 1); value = v[floor] + fraction * (v[floor + 1] - v[floor])
-- This is the same definition as PERCENTILE_CONT / pandas' default quantile.
-- -----------------------------------------------------------------------------
-- @result: Price, freight and payment ranges (BRL)
WITH v(measure, val) AS (
    SELECT 'order_items.price', price FROM raw_order_items
    UNION ALL SELECT 'order_items.freight_value', freight_value FROM raw_order_items
    UNION ALL SELECT 'order_payments.payment_value', payment_value FROM raw_order_payments
),
ranked AS (
    SELECT measure, val,
           ROW_NUMBER() OVER (PARTITION BY measure ORDER BY val) - 1 AS i,
           COUNT(*) OVER (PARTITION BY measure) AS n
    FROM v
),
pcts(p) AS (VALUES (0.5), (0.99)),
pct_values AS (
    SELECT r.measure, q.p,
           SUM(CASE WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER)
                    THEN r.val * (1 - (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER)))
                    WHEN r.i = CAST(q.p * (r.n - 1) AS INTEGER) + 1
                    THEN r.val * (q.p * (r.n - 1) - CAST(q.p * (r.n - 1) AS INTEGER))
                    ELSE 0 END) AS pv
    FROM ranked r CROSS JOIN pcts q
    GROUP BY r.measure, q.p
)
SELECT v.measure,
       MIN(v.val) AS min_value,
       (SELECT pv FROM pct_values x WHERE x.measure = v.measure AND x.p = 0.5)  AS median_value,
       (SELECT pv FROM pct_values x WHERE x.measure = v.measure AND x.p = 0.99) AS p99_value,
       MAX(v.val) AS max_value,
       COUNT(*) FILTER (WHERE v.val <= 0) AS non_positive_rows
FROM v
GROUP BY v.measure
ORDER BY CASE v.measure WHEN 'order_items.price' THEN 1 WHEN 'order_items.freight_value' THEN 2 ELSE 3 END;

-- @result: Payment type and installment anomalies
SELECT payment_type,
       COUNT(*) AS payment_rows,
       COUNT(*) FILTER (WHERE payment_installments = 0) AS zero_installments,
       MIN(payment_installments) AS min_installments,
       MAX(payment_installments) AS max_installments
FROM raw_order_payments
GROUP BY payment_type
ORDER BY payment_rows DESC;

-- @result: Items+freight vs payments reconciliation (orders that have both)
WITH items AS (
    SELECT order_id, SUM(price + freight_value) AS items_value FROM raw_order_items GROUP BY order_id
), pays AS (
    SELECT order_id, SUM(payment_value) AS paid_value FROM raw_order_payments GROUP BY order_id
)
SELECT COUNT(*) AS orders_with_items_and_payments,
       COUNT(*) FILTER (WHERE ABS(items_value - paid_value) > 1.00) AS orders_differing_by_more_than_1_brl,
       ROUND(SUM(items_value), 2) AS total_items_plus_freight_brl,
       ROUND(SUM(paid_value), 2)  AS total_payments_brl
FROM items JOIN pays ON pays.order_id = items.order_id;

-- @result: Duplicate full rows in raw tables
SELECT 'order_items' AS table_name, COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_order_items)) AS exact_duplicate_rows FROM raw_order_items
UNION ALL SELECT 'order_payments', COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_order_payments)) FROM raw_order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_order_reviews))  FROM raw_order_reviews
UNION ALL SELECT 'geolocation',    COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM raw_geolocation))    FROM raw_geolocation;
