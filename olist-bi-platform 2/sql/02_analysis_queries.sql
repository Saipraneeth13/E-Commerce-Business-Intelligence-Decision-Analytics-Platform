-- =====================================================================
-- Olist BI Platform - 29 analysis queries (PostgreSQL 13+)
-- Sections: A Sales | B Delivery | C Satisfaction | D Retention | E Cancellations
-- Definitions: revenue = SUM(price) on delivered orders; late = delivered after estimate
-- Uses view vw_order_master (see 01_schema.sql)
-- =====================================================================

-- ############################  A. SALES  ############################

-- Q01 | Headline KPIs (CTE)
WITH delivered AS (
    SELECT * FROM vw_order_master WHERE is_delivered
), reviews AS (
    SELECT AVG(review_score) AS avg_review FROM vw_order_master
)
SELECT (SELECT COUNT(*) FROM vw_order_master)                               AS total_orders,
       COUNT(*)                                                             AS delivered_orders,
       ROUND(SUM(revenue), 2)                                               AS total_revenue,
       ROUND(AVG(revenue), 2)                                               AS avg_order_value,
       ROUND(AVG(delivery_days), 1)                                         AS avg_delivery_days,
       ROUND(100.0 * AVG(is_late) FILTER (WHERE order_delivered_customer_date IS NOT NULL), 2) AS late_rate_pct,
       ROUND((SELECT avg_review FROM reviews), 2)                           AS avg_review_score,
       ROUND(100.0 * (SELECT COUNT(*) FROM orders WHERE order_status = 'canceled')
             / (SELECT COUNT(*) FROM orders), 2)                            AS cancellation_rate_pct
FROM delivered;

-- Q02 | Monthly revenue with month-over-month growth (LAG)
WITH monthly AS (
    SELECT purchase_month, COUNT(*) AS orders, SUM(revenue) AS revenue
    FROM vw_order_master
    WHERE is_delivered AND purchase_month BETWEEN '2017-01' AND '2018-08'
    GROUP BY purchase_month
)
SELECT purchase_month, orders, ROUND(revenue, 2) AS revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER w) / NULLIF(LAG(revenue) OVER w, 0), 1) AS mom_growth_pct
FROM monthly
WINDOW w AS (ORDER BY purchase_month)
ORDER BY purchase_month;

-- Q03 | Revenue by category with share and cumulative share (window SUM)
WITH cat AS (
    SELECT p.product_category_english AS category,
           SUM(oi.price) AS revenue, COUNT(*) AS items_sold
    FROM order_items oi
    JOIN orders o   ON o.order_id = oi.order_id AND o.order_status = 'delivered'
    JOIN products p ON p.product_id = oi.product_id
    GROUP BY 1
)
SELECT category, ROUND(revenue, 2) AS revenue, items_sold,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)                                   AS share_pct,
       ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER (), 2) AS cumulative_share_pct
FROM cat
ORDER BY revenue DESC;

-- Q04 | Top-5 category concentration (CTE + RANK)  -> 39.8% of revenue
WITH cat AS (
    SELECT p.product_category_english AS category, SUM(oi.price) AS revenue
    FROM order_items oi
    JOIN orders o   ON o.order_id = oi.order_id AND o.order_status = 'delivered'
    JOIN products p ON p.product_id = oi.product_id
    GROUP BY 1
), ranked AS (
    SELECT category, revenue, RANK() OVER (ORDER BY revenue DESC) AS rnk FROM cat
)
SELECT ROUND(100.0 * SUM(revenue) FILTER (WHERE rnk <= 5) / SUM(revenue), 1) AS top5_share_pct,
       STRING_AGG(category, ', ' ORDER BY rnk) FILTER (WHERE rnk <= 5)        AS top5_categories
FROM ranked;

-- Q05 | Category ranking per year (DENSE_RANK partitioned) - are leaders stable?
WITH yr AS (
    SELECT EXTRACT(YEAR FROM o.order_purchase_timestamp)::INT AS yr,
           p.product_category_english AS category, SUM(oi.price) AS revenue
    FROM order_items oi
    JOIN orders o   ON o.order_id = oi.order_id AND o.order_status = 'delivered'
    JOIN products p ON p.product_id = oi.product_id
    WHERE o.order_purchase_timestamp >= '2017-01-01'
    GROUP BY 1, 2
)
SELECT *
FROM (SELECT yr, category, ROUND(revenue, 2) AS revenue,
             DENSE_RANK() OVER (PARTITION BY yr ORDER BY revenue DESC) AS rnk
      FROM yr) t
WHERE rnk <= 5
ORDER BY yr, rnk;

-- Q06 | Revenue, AOV and late rate by customer state
SELECT customer_state,
       COUNT(*)                         AS orders,
       ROUND(SUM(revenue), 2)           AS revenue,
       ROUND(AVG(revenue), 2)           AS avg_order_value,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS revenue_share_pct
FROM vw_order_master
WHERE is_delivered
GROUP BY customer_state
ORDER BY revenue DESC;

-- Q07 | Payment method mix
SELECT payment_type, COUNT(*) AS payments,
       ROUND(SUM(payment_value), 2) AS total_value,
       ROUND(AVG(payment_installments), 2) AS avg_installments,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS share_pct
FROM order_payments
GROUP BY payment_type
ORDER BY total_value DESC;

-- Q08 | Order value by installment bucket (CASE)
SELECT CASE WHEN installments = 1 THEN '1 (single)'
            WHEN installments BETWEEN 2 AND 4 THEN '2-4'
            WHEN installments BETWEEN 5 AND 8 THEN '5-8'
            ELSE '9+' END AS installment_bucket,
       COUNT(*) AS orders, ROUND(AVG(revenue), 2) AS avg_order_value
FROM vw_order_master
WHERE is_delivered AND installments IS NOT NULL
GROUP BY 1
ORDER BY MIN(installments);

-- Q09 | Seller Pareto: revenue share by seller decile (NTILE)
WITH seller_rev AS (
    SELECT oi.seller_id, SUM(oi.price) AS revenue
    FROM order_items oi JOIN orders o ON o.order_id = oi.order_id AND o.order_status = 'delivered'
    GROUP BY 1
), decile AS (
    SELECT *, NTILE(10) OVER (ORDER BY revenue DESC) AS dec FROM seller_rev
)
SELECT dec AS seller_decile, COUNT(*) AS sellers, ROUND(SUM(revenue), 2) AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1) AS share_pct
FROM decile GROUP BY dec ORDER BY dec;

-- Q10 | Seller scorecard: revenue, late rate and review (min 30 orders)
SELECT oi.seller_id, s.seller_state,
       COUNT(DISTINCT oi.order_id)                                  AS orders,
       ROUND(SUM(oi.price), 2)                                      AS revenue,
       ROUND(100.0 * AVG(m.is_late), 1)                             AS late_rate_pct,
       ROUND(AVG(m.review_score), 2)                                AS avg_review
FROM order_items oi
JOIN sellers s          ON s.seller_id = oi.seller_id
JOIN vw_order_master m  ON m.order_id = oi.order_id AND m.is_delivered
GROUP BY oi.seller_id, s.seller_state
HAVING COUNT(DISTINCT oi.order_id) >= 30
ORDER BY revenue DESC
LIMIT 20;

-- ############################  B. DELIVERY  ############################

-- Q11 | Overall late-delivery rate  -> 8.1%
SELECT COUNT(*)                                   AS delivered_orders,
       SUM(is_late)                               AS late_orders,
       ROUND(100.0 * SUM(is_late) / COUNT(*), 2)  AS late_rate_pct
FROM orders
WHERE is_delivered AND order_delivered_customer_date IS NOT NULL;

-- Q12 | Late rate by customer state, with national benchmark (window AVG)
WITH st AS (
    SELECT c.customer_state, COUNT(*) AS orders, SUM(o.is_late) AS late_orders,
           AVG(o.delivery_days) AS avg_delivery_days
    FROM orders o JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.is_delivered AND o.order_delivered_customer_date IS NOT NULL
    GROUP BY 1
)
SELECT customer_state, orders,
       ROUND(100.0 * late_orders / orders, 2)                            AS late_rate_pct,
       ROUND(100.0 * SUM(late_orders) OVER () / SUM(orders) OVER (), 2)  AS national_late_rate_pct,
       ROUND(avg_delivery_days::NUMERIC, 1)                              AS avg_delivery_days
FROM st
WHERE orders >= 500
ORDER BY late_rate_pct DESC;

-- Q13 | Review score: on-time vs late  -> 4.29 vs 2.57
SELECT CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time' END AS delivery_outcome,
       COUNT(*)                         AS orders,
       ROUND(AVG(review_score), 2)      AS avg_review_score,
       ROUND(100.0 * AVG((review_score <= 2)::INT), 1) AS pct_1_2_stars
FROM vw_order_master
WHERE is_delivered AND order_delivered_customer_date IS NOT NULL AND review_score IS NOT NULL
GROUP BY 1
ORDER BY 1 DESC;

-- Q14 | Review score by how early/late the order arrived (CASE buckets)
SELECT CASE WHEN delay_days <= -7 THEN '1. 7+ days early'
            WHEN delay_days <= 0  THEN '2. 0-7 days early'
            WHEN delay_days <= 3  THEN '3. 1-3 days late'
            WHEN delay_days <= 7  THEN '4. 4-7 days late'
            WHEN delay_days <= 14 THEN '5. 8-14 days late'
            ELSE '6. 15+ days late' END AS arrival_bucket,
       COUNT(*) AS orders, ROUND(AVG(review_score), 2) AS avg_review
FROM vw_order_master
WHERE is_delivered AND order_delivered_customer_date IS NOT NULL AND review_score IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- Q15 | Monthly late rate with 3-month moving average (window frame)
WITH m AS (
    SELECT purchase_month, COUNT(*) AS orders, 100.0 * AVG(is_late) AS late_rate
    FROM orders
    WHERE is_delivered AND order_delivered_customer_date IS NOT NULL
      AND purchase_month BETWEEN '2017-01' AND '2018-08'
    GROUP BY 1
)
SELECT purchase_month, orders, ROUND(late_rate, 2) AS late_rate_pct,
       ROUND(AVG(late_rate) OVER (ORDER BY purchase_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS late_rate_3m_avg
FROM m ORDER BY purchase_month;

-- Q16 | Same-state vs cross-state shipments: delivery time and late rate
WITH first_item AS (
    SELECT DISTINCT ON (order_id) order_id, seller_id
    FROM order_items ORDER BY order_id, order_item_id
)
SELECT CASE WHEN s.seller_state = c.customer_state THEN 'Same state' ELSE 'Cross state' END AS shipment_type,
       COUNT(*) AS orders,
       ROUND(AVG(o.delivery_days)::NUMERIC, 1) AS avg_delivery_days,
       ROUND(100.0 * AVG(o.is_late), 2)        AS late_rate_pct
FROM orders o
JOIN first_item fi ON fi.order_id = o.order_id
JOIN sellers s     ON s.seller_id = fi.seller_id
JOIN customers c   ON c.customer_id = o.customer_id
WHERE o.is_delivered AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1;

-- Q17 | Category-level late rate and review (min 300 orders) with rank
WITH cat AS (
    SELECT p.product_category_english AS category,
           COUNT(DISTINCT m.order_id) AS orders,
           100.0 * AVG(m.is_late) AS late_rate, AVG(m.review_score) AS avg_review
    FROM order_items oi
    JOIN vw_order_master m ON m.order_id = oi.order_id AND m.is_delivered
                          AND m.order_delivered_customer_date IS NOT NULL
    JOIN products p        ON p.product_id = oi.product_id
    GROUP BY 1 HAVING COUNT(DISTINCT m.order_id) >= 300
)
SELECT category, orders, ROUND(late_rate, 2) AS late_rate_pct, ROUND(avg_review, 2) AS avg_review,
       RANK() OVER (ORDER BY late_rate DESC) AS late_rank
FROM cat ORDER BY late_rank LIMIT 15;

-- Q18 | Estimate accuracy: promised vs actual delivery days by state
SELECT c.customer_state,
       ROUND(AVG(o.estimated_days)::NUMERIC, 1) AS avg_promised_days,
       ROUND(AVG(o.delivery_days)::NUMERIC, 1)  AS avg_actual_days,
       ROUND(AVG(o.estimated_days - o.delivery_days)::NUMERIC, 1) AS avg_buffer_days
FROM orders o JOIN customers c ON c.customer_id = o.customer_id
WHERE o.is_delivered AND o.order_delivered_customer_date IS NOT NULL
GROUP BY 1 HAVING COUNT(*) >= 500
ORDER BY avg_buffer_days;

-- ############################  C. SATISFACTION  ############################

-- Q19 | Review score distribution
SELECT review_score, COUNT(*) AS reviews,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct
FROM order_reviews GROUP BY review_score ORDER BY review_score DESC;

-- Q20 | Lowest-rated categories (min 200 reviewed orders) - RANK
WITH cat AS (
    SELECT p.product_category_english AS category, COUNT(DISTINCT m.order_id) AS orders,
           AVG(m.review_score) AS avg_review
    FROM order_items oi
    JOIN vw_order_master m ON m.order_id = oi.order_id AND m.review_score IS NOT NULL
    JOIN products p        ON p.product_id = oi.product_id
    GROUP BY 1 HAVING COUNT(DISTINCT m.order_id) >= 200
)
SELECT category, orders, ROUND(avg_review, 2) AS avg_review,
       RANK() OVER (ORDER BY avg_review) AS worst_rank
FROM cat ORDER BY worst_rank LIMIT 10;

-- Q21 | Do unhappy customers leave comments? (comment rate by score)
SELECT review_score, COUNT(*) AS reviews,
       ROUND(100.0 * AVG(has_comment::INT), 1) AS pct_with_comment
FROM order_reviews GROUP BY review_score ORDER BY review_score;

-- Q22 | Orders with more than one review (data-quality check, window COUNT in subquery)
SELECT order_id, review_id, review_score, review_answer_timestamp, reviews_for_order
FROM (SELECT *, COUNT(*) OVER (PARTITION BY order_id) AS reviews_for_order FROM order_reviews) t
WHERE reviews_for_order > 1
ORDER BY order_id, review_answer_timestamp
LIMIT 20;

-- ############################  D. RETENTION  ############################

-- Q23 | Repeat-customer rate  -> 3.1%
WITH per_customer AS (
    SELECT customer_unique_id, COUNT(DISTINCT order_id) AS orders
    FROM vw_order_master GROUP BY 1
)
SELECT COUNT(*)                                          AS unique_customers,
       COUNT(*) FILTER (WHERE orders > 1)                AS repeat_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE orders > 1) / COUNT(*), 2) AS repeat_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE orders > 1) / COUNT(*) * 1.10, 2) AS target_rate_with_10pct_lift
FROM per_customer;

-- Q24 | Orders-per-customer distribution
WITH per_customer AS (
    SELECT customer_unique_id, COUNT(DISTINCT order_id) AS orders FROM vw_order_master GROUP BY 1
)
SELECT orders AS orders_placed, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS share_pct
FROM per_customer GROUP BY 1 ORDER BY 1;

-- Q25 | Days between first and second order (ROW_NUMBER + LEAD-style self join)
WITH ranked AS (
    SELECT customer_unique_id, order_purchase_timestamp,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY order_purchase_timestamp) AS rn
    FROM vw_order_master
)
SELECT COUNT(*) AS repeat_customers,
       ROUND(AVG(EXTRACT(EPOCH FROM (b.order_purchase_timestamp - a.order_purchase_timestamp)) / 86400)::NUMERIC, 1) AS avg_days_to_second_order,
       PERCENTILE_CONT(0.5) WITHIN GROUP (
           ORDER BY EXTRACT(EPOCH FROM (b.order_purchase_timestamp - a.order_purchase_timestamp)) / 86400) AS median_days
FROM ranked a JOIN ranked b ON a.customer_unique_id = b.customer_unique_id AND a.rn = 1 AND b.rn = 2;

-- Q26 | Does a bad FIRST experience reduce repeat purchases?
WITH first_order AS (
    SELECT DISTINCT ON (customer_unique_id) customer_unique_id, review_score, is_late
    FROM vw_order_master ORDER BY customer_unique_id, order_purchase_timestamp
), cnt AS (
    SELECT customer_unique_id, COUNT(DISTINCT order_id) AS orders FROM vw_order_master GROUP BY 1
)
SELECT CASE WHEN f.review_score <= 2 THEN '1-2 (poor)' WHEN f.review_score = 3 THEN '3 (neutral)'
            WHEN f.review_score >= 4 THEN '4-5 (good)' END AS first_order_review,
       COUNT(*) AS customers,
       ROUND(100.0 * AVG((c.orders > 1)::INT), 2) AS repeat_rate_pct
FROM first_order f JOIN cnt c USING (customer_unique_id)
WHERE f.review_score IS NOT NULL
GROUP BY 1 ORDER BY 1 DESC;

-- Q27 | Monthly cohort retention: % of each first-purchase cohort that orders again
WITH firsts AS (
    SELECT customer_unique_id, MIN(DATE_TRUNC('month', order_purchase_timestamp)) AS cohort
    FROM vw_order_master GROUP BY 1
), activity AS (
    SELECT f.cohort,
           (EXTRACT(YEAR FROM AGE(DATE_TRUNC('month', m.order_purchase_timestamp), f.cohort)) * 12
            + EXTRACT(MONTH FROM AGE(DATE_TRUNC('month', m.order_purchase_timestamp), f.cohort)))::INT AS month_n,
           m.customer_unique_id
    FROM vw_order_master m JOIN firsts f USING (customer_unique_id)
), sizes AS (
    SELECT cohort, COUNT(*) AS cohort_size FROM firsts GROUP BY 1
)
SELECT TO_CHAR(a.cohort, 'YYYY-MM') AS cohort, s.cohort_size, a.month_n,
       COUNT(DISTINCT a.customer_unique_id) AS active_customers,
       ROUND(100.0 * COUNT(DISTINCT a.customer_unique_id) / s.cohort_size, 2) AS retention_pct
FROM activity a JOIN sizes s USING (cohort)
WHERE a.cohort BETWEEN '2017-01-01' AND '2017-12-01' AND a.month_n BETWEEN 1 AND 6
GROUP BY a.cohort, s.cohort_size, a.month_n
ORDER BY a.cohort, a.month_n;

-- ############################  E. CANCELLATIONS  ############################

-- Q28 | Order status breakdown and monthly cancellation rate
SELECT order_status, COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS share_pct
FROM orders GROUP BY order_status ORDER BY orders DESC;

-- Q29 | Monthly cancellation rate with running total (cumulative window)
SELECT purchase_month,
       COUNT(*) AS orders,
       COUNT(*) FILTER (WHERE order_status = 'canceled') AS canceled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_status = 'canceled') / COUNT(*), 2) AS cancel_rate_pct,
       SUM(COUNT(*) FILTER (WHERE order_status = 'canceled')) OVER (ORDER BY purchase_month) AS cumulative_canceled
FROM orders
WHERE purchase_month BETWEEN '2017-01' AND '2018-08'
GROUP BY purchase_month ORDER BY purchase_month;
