-- =============================================================================
-- 01_create_schema.sql
-- Project : Improving E-Commerce Delivery Performance and Customer Reviews
-- Engine  : SQLite 3 (Python's built-in sqlite3 module)
-- Database: data/processed/olist.db (rebuilt from scratch by scripts/build_database.py)
-- Purpose : Create typed staging tables for the nine raw Olist CSVs.
--
-- SQLite has no CREATE SCHEMA, so the two layers are separated by name:
--   raw_*                     -> one table per source CSV, loaded as-is
--                                (no rows dropped, no values changed)
--   fct_*, dim_*, stg_*,
--   order_sellers,
--   order_categories          -> cleaned, analysis-ready layer (03_transform.sql)
--
-- Type decisions
--   * Zip code prefixes are TEXT: they carry leading zeros ("01001").
--   * IDs are 32-char hex strings -> TEXT.
--   * Timestamps are TEXT in ISO-8601 'YYYY-MM-DD HH:MM:SS' (local Brazil time,
--     no time zone). ISO text sorts and compares correctly and works with
--     SQLite's date(), strftime() and unixepoch() functions.
--   * Money columns are REAL, Brazilian reais (BRL).
--   * Flags created later are INTEGER 0/1 (SQLite has no BOOLEAN type).
-- =============================================================================

DROP TABLE IF EXISTS raw_orders;
DROP TABLE IF EXISTS raw_order_items;
DROP TABLE IF EXISTS raw_order_payments;
DROP TABLE IF EXISTS raw_order_reviews;
DROP TABLE IF EXISTS raw_customers;
DROP TABLE IF EXISTS raw_sellers;
DROP TABLE IF EXISTS raw_products;
DROP TABLE IF EXISTS raw_product_category_name_translation;
DROP TABLE IF EXISTS raw_geolocation;

-- Grain: one row per order (order_id). Every order has exactly one customer_id.
CREATE TABLE raw_orders (
    order_id                       TEXT,
    customer_id                    TEXT,
    order_status                   TEXT,
    order_purchase_timestamp       TEXT,
    order_approved_at              TEXT,
    order_delivered_carrier_date   TEXT,
    order_delivered_customer_date  TEXT,
    order_estimated_delivery_date  TEXT
);

-- Grain: one row per item within an order (order_id, order_item_id).
CREATE TABLE raw_order_items (
    order_id             TEXT,
    order_item_id        INTEGER,
    product_id           TEXT,
    seller_id            TEXT,
    shipping_limit_date  TEXT,
    price                REAL,
    freight_value        REAL
);

-- Grain: one row per payment record within an order (order_id, payment_sequential).
CREATE TABLE raw_order_payments (
    order_id              TEXT,
    payment_sequential    INTEGER,
    payment_type          TEXT,
    payment_installments  INTEGER,
    payment_value         REAL
);

-- Grain: one row per (review_id, order_id). NOTE: review_id alone is NOT unique
-- and some orders have more than one review (validated in 02_load_and_validate.sql).
CREATE TABLE raw_order_reviews (
    review_id                TEXT,
    order_id                 TEXT,
    review_score             INTEGER,
    review_comment_title     TEXT,
    review_comment_message   TEXT,
    review_creation_date     TEXT,
    review_answer_timestamp  TEXT
);

-- Grain: one row per customer_id. customer_id is generated per order;
-- customer_unique_id identifies the same person across orders.
CREATE TABLE raw_customers (
    customer_id               TEXT,
    customer_unique_id        TEXT,
    customer_zip_code_prefix  TEXT,
    customer_city             TEXT,
    customer_state            TEXT
);

-- Grain: one row per seller_id.
CREATE TABLE raw_sellers (
    seller_id               TEXT,
    seller_zip_code_prefix  TEXT,
    seller_city             TEXT,
    seller_state            TEXT
);

-- Grain: one row per product_id. Column names keep the source misspelling
-- ("lenght") so the raw layer matches the CSV exactly.
CREATE TABLE raw_products (
    product_id                  TEXT,
    product_category_name       TEXT,
    product_name_lenght         INTEGER,
    product_description_lenght  INTEGER,
    product_photos_qty          INTEGER,
    product_weight_g            INTEGER,
    product_length_cm           INTEGER,
    product_height_cm           INTEGER,
    product_width_cm            INTEGER
);

-- Grain: one row per Portuguese category name.
CREATE TABLE raw_product_category_name_translation (
    product_category_name          TEXT,
    product_category_name_english  TEXT
);

-- Grain: NOT unique. Many rows per zip prefix (multiple lat/lng points).
-- Loaded for completeness; not used in the analytics model (see docs/methodology.md).
CREATE TABLE raw_geolocation (
    geolocation_zip_code_prefix  TEXT,
    geolocation_lat              REAL,
    geolocation_lng              REAL,
    geolocation_city             TEXT,
    geolocation_state            TEXT
);
