-- =====================================================================
-- Olist BI Platform - PostgreSQL schema (loads the cleaned CSVs)
-- =====================================================================
DROP VIEW  IF EXISTS vw_order_master CASCADE;
DROP TABLE IF EXISTS order_reviews, order_payments, order_items, orders, customers,
                     sellers, products, category_translation, geolocation, geolocation_zip CASCADE;

CREATE TABLE category_translation (
    product_category_name          TEXT PRIMARY KEY,
    product_category_name_english  TEXT NOT NULL
);

CREATE TABLE products (
    product_id                  TEXT PRIMARY KEY,
    product_category_name       TEXT NOT NULL,                 -- 'unknown' where originally NULL
    product_name_length         NUMERIC,
    product_description_length  NUMERIC,
    product_photos_qty          NUMERIC,
    product_weight_g            NUMERIC,
    product_length_cm           NUMERIC,
    product_height_cm           NUMERIC,
    product_width_cm            NUMERIC,
    product_category_english    TEXT NOT NULL
);

CREATE TABLE customers (
    customer_id               TEXT PRIMARY KEY,                -- one per order
    customer_unique_id        TEXT NOT NULL,                   -- the real person
    customer_zip_code_prefix  INT,
    customer_city             TEXT,
    customer_state            CHAR(2)
);

CREATE TABLE sellers (
    seller_id               TEXT PRIMARY KEY,
    seller_zip_code_prefix  INT,
    seller_city             TEXT,
    seller_state            CHAR(2)
);

CREATE TABLE orders (
    order_id                       TEXT PRIMARY KEY,
    customer_id                    TEXT NOT NULL REFERENCES customers(customer_id),
    order_status                   TEXT NOT NULL,
    order_purchase_timestamp       TIMESTAMP,
    order_approved_at              TIMESTAMP,
    order_delivered_carrier_date   TIMESTAMP,
    order_delivered_customer_date  TIMESTAMP,
    order_estimated_delivery_date  TIMESTAMP,
    is_delivered                   BOOLEAN,
    delivery_days                  NUMERIC,
    estimated_days                 NUMERIC,
    delay_days                     NUMERIC,
    is_late                        SMALLINT,                   -- 1 late, 0 on time, NULL n/a
    purchase_month                 CHAR(7)
);

CREATE TABLE order_items (
    order_id             TEXT NOT NULL REFERENCES orders(order_id),
    order_item_id        INT  NOT NULL,
    product_id           TEXT NOT NULL REFERENCES products(product_id),
    seller_id            TEXT NOT NULL REFERENCES sellers(seller_id),
    shipping_limit_date  TIMESTAMP,
    price                NUMERIC(10,2) NOT NULL,
    freight_value        NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE order_payments (
    order_id              TEXT NOT NULL REFERENCES orders(order_id),
    payment_sequential    INT  NOT NULL,
    payment_type          TEXT,
    payment_installments  INT,
    payment_value         NUMERIC(10,2),
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE order_reviews (
    review_id                TEXT NOT NULL,
    order_id                 TEXT NOT NULL REFERENCES orders(order_id),
    review_score             SMALLINT CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title     TEXT,
    review_comment_message   TEXT,
    review_creation_date     TIMESTAMP,
    review_answer_timestamp  TIMESTAMP,
    has_comment              BOOLEAN,
    PRIMARY KEY (review_id, order_id)
);

CREATE TABLE geolocation (
    geolocation_zip_code_prefix  INT,
    geolocation_lat              DOUBLE PRECISION,
    geolocation_lng              DOUBLE PRECISION,
    geolocation_city             TEXT,
    geolocation_state            CHAR(2)
);

CREATE TABLE geolocation_zip (
    zip_code_prefix  INT PRIMARY KEY,
    lat              DOUBLE PRECISION,
    lng              DOUBLE PRECISION,
    city             TEXT,
    state            CHAR(2)
);

-- Indexes for the join paths used by the analysis queries
CREATE INDEX idx_orders_customer   ON orders(customer_id);
CREATE INDEX idx_orders_status     ON orders(order_status);
CREATE INDEX idx_orders_month      ON orders(purchase_month);
CREATE INDEX idx_items_product     ON order_items(product_id);
CREATE INDEX idx_items_seller      ON order_items(seller_id);
CREATE INDEX idx_reviews_order     ON order_reviews(order_id);
CREATE INDEX idx_customers_unique  ON customers(customer_unique_id);

-- ---------------------------------------------------------------------
-- Order-level view: one row per order (this is the Power BI fact table)
-- ---------------------------------------------------------------------
CREATE VIEW vw_order_master AS
WITH item_agg AS (
    SELECT order_id, COUNT(*) AS items, SUM(price) AS revenue, SUM(freight_value) AS freight
    FROM order_items GROUP BY order_id
), pay_agg AS (
    SELECT order_id, SUM(payment_value) AS payment_value, MAX(payment_installments) AS installments
    FROM order_payments GROUP BY order_id
), review_latest AS (
    SELECT DISTINCT ON (order_id) order_id, review_score
    FROM order_reviews
    ORDER BY order_id, review_answer_timestamp DESC
)
SELECT o.*, c.customer_unique_id, c.customer_city, c.customer_state,
       i.items, i.revenue, i.freight, p.payment_value, p.installments, r.review_score
FROM orders o
JOIN customers c           ON c.customer_id = o.customer_id
LEFT JOIN item_agg i       ON i.order_id = o.order_id
LEFT JOIN pay_agg p        ON p.order_id = o.order_id
LEFT JOIN review_latest r  ON r.order_id = o.order_id;
