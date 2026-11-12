-- reporting_queries.sql : Week 4 Dynamic Reporting (PostgreSQL)

-- ============================================================
-- Query 1: Best-Selling Products (Top 10 by Revenue)
-- Business question: Which products generate the most revenue and units, and which category do they belong to?
-- Technique: Multi-table JOIN + aggregation
-- ============================================================
SELECT p.product_id,
       p.product_name,
       c.category_name,
       SUM(oi.quantity)                                      AS units_sold,
       ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount)), 2) AS revenue
FROM   order_items oi
JOIN   orders      o ON o.order_id    = oi.order_id
JOIN   products    p ON p.product_id  = oi.product_id
JOIN   categories  c ON c.category_id = p.category_id
WHERE  o.status = 'COMPLETED'
  AND  o.order_date >= DATE '2025-01-01'
  AND  o.order_date <  DATE '2026-01-01'
GROUP  BY p.product_id, p.product_name, c.category_name
ORDER  BY revenue DESC
LIMIT  10;

-- ============================================================
-- Query 2: Monthly Sales Trend with Month-over-Month Growth
-- Business question: How are revenue and order volume changing month by month?
-- Technique: CTE + window function (LAG)
-- ============================================================
WITH monthly AS (
    SELECT DATE_TRUNC('month', o.order_date)::date AS month_start,
           SUM(oi.quantity * oi.unit_price * (1 - oi.discount)) AS revenue,
           COUNT(DISTINCT o.order_id) AS orders
    FROM   orders o
    JOIN   order_items oi ON oi.order_id = o.order_id
    WHERE  o.status = 'COMPLETED'
      AND  o.order_date >= DATE '2025-01-01'
      AND  o.order_date <  DATE '2026-01-01'
    GROUP  BY 1
)
SELECT month_start,
       ROUND(revenue, 0) AS revenue,
       orders,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month_start))
             / NULLIF(LAG(revenue) OVER (ORDER BY month_start), 0), 1) AS mom_growth_pct
FROM   monthly
ORDER  BY month_start;

-- ============================================================
-- Query 3: Inventory Turnover by Category
-- Business question: How quickly does stock in each category convert into sales, and how many days of stock are we holding?
-- Technique: Multiple CTEs + subquery + ratio metrics
-- ============================================================
WITH cogs AS (
    SELECT p.category_id,
           SUM(oi.quantity * p.unit_cost) AS cogs
    FROM   order_items oi
    JOIN   orders   o ON o.order_id   = oi.order_id
    JOIN   products p ON p.product_id = oi.product_id
    WHERE  o.status = 'COMPLETED'
      AND  o.order_date >= DATE '2025-01-01'
      AND  o.order_date <  DATE '2026-01-01'
    GROUP  BY p.category_id
),
avg_inv AS (
    SELECT category_id, AVG(inv_value) AS avg_inventory_value
    FROM  (SELECT s.snapshot_date, p.category_id,
                  SUM(s.stock_qty * p.unit_cost) AS inv_value
           FROM   inventory_snapshots s
           JOIN   products p ON p.product_id = s.product_id
           WHERE  s.snapshot_date >= DATE '2025-01-01'
             AND  s.snapshot_date <  DATE '2026-01-01'
           GROUP  BY s.snapshot_date, p.category_id) daily
    GROUP  BY category_id
)
SELECT c.category_name,
       ROUND(g.cogs, 0)                                    AS cogs,
       ROUND(a.avg_inventory_value, 0)                     AS avg_inventory_value,
       ROUND(g.cogs / NULLIF(a.avg_inventory_value, 0), 2) AS turnover_ratio,
       ROUND(365 / NULLIF(g.cogs / NULLIF(a.avg_inventory_value, 0), 0), 0)
                                                           AS days_of_inventory
FROM   cogs g
JOIN   avg_inv a    ON a.category_id = g.category_id
JOIN   categories c ON c.category_id = g.category_id
ORDER  BY turnover_ratio DESC;

-- ============================================================
-- Query 4: Seasonal Sales Pattern by Category
-- Business question: Which categories drive the seasonal peaks across the year?
-- Technique: Conditional aggregation (FILTER) to pivot rows into columns
-- ============================================================
WITH line AS (
    SELECT o.order_date,
           c.category_name,
           oi.quantity * oi.unit_price * (1 - oi.discount) AS rev
    FROM   orders o
    JOIN   order_items oi ON oi.order_id   = o.order_id
    JOIN   products    p  ON p.product_id  = oi.product_id
    JOIN   categories  c  ON c.category_id = p.category_id
    WHERE  o.status = 'COMPLETED'
      AND  o.order_date >= DATE '2025-01-01'
      AND  o.order_date <  DATE '2026-01-01'
)
SELECT EXTRACT(MONTH FROM order_date)::int AS month_no,
       TO_CHAR(order_date, 'Mon')          AS month_name,
       ROUND(SUM(rev) FILTER (WHERE category_name = 'Electronics'), 0)    AS electronics,
       ROUND(SUM(rev) FILTER (WHERE category_name = 'Apparel'), 0)        AS apparel,
       ROUND(SUM(rev) FILTER (WHERE category_name = 'Grocery'), 0)        AS grocery,
       ROUND(SUM(rev) FILTER (WHERE category_name = 'Home & Kitchen'), 0) AS home_kitchen
FROM   line
GROUP  BY 1, 2
ORDER  BY 1;

-- ============================================================
-- Query 5: Customer Segmentation using RFM Scoring
-- Business question: Who are the best customers, who is at risk of churning, and who is new?
-- Technique: CTEs + NTILE window functions + CASE
-- ============================================================
WITH cust AS (
    SELECT c.customer_id,
           c.customer_name,
           MAX(o.order_date)               AS last_order,
           COUNT(DISTINCT o.order_id)      AS frequency,
           ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount)), 2) AS monetary
    FROM   customers c
    JOIN   orders      o  ON o.customer_id = c.customer_id
    JOIN   order_items oi ON oi.order_id   = o.order_id
    WHERE  o.status = 'COMPLETED'
    GROUP  BY c.customer_id, c.customer_name
),
scored AS (
    SELECT cust.*,
           NTILE(5) OVER (ORDER BY last_order) AS r_score,   -- 5 = most recent
           NTILE(5) OVER (ORDER BY frequency)  AS f_score,
           NTILE(5) OVER (ORDER BY monetary)   AS m_score
    FROM   cust
)
SELECT customer_id, customer_name, last_order, frequency, monetary,
       r_score, f_score, m_score,
       CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champion'
            WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal'
            WHEN r_score <= 2 AND f_score >= 3                  THEN 'At Risk'
            WHEN r_score >= 4 AND f_score <= 2                  THEN 'New Customer'
            ELSE 'Needs Attention'
       END AS segment
FROM   scored
ORDER  BY monetary DESC
LIMIT  10;

-- ============================================================
-- Query 6: Low-Stock and Reorder Alert Report
-- Business question: Which products will run out soon, given how fast they are actually selling?
-- Technique: CTE + LEFT JOIN + derived metric (days of cover) + CASE
-- ============================================================
WITH velocity AS (
    SELECT oi.product_id,
           SUM(oi.quantity) / 30.0 AS avg_daily_units
    FROM   order_items oi
    JOIN   orders o ON o.order_id = oi.order_id
    WHERE  o.status = 'COMPLETED'
      AND  o.order_date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP  BY oi.product_id
)
SELECT p.product_id,
       p.product_name,
       i.stock_qty,
       i.reorder_level,
       ROUND(v.avg_daily_units, 1)                         AS daily_sales,
       ROUND(i.stock_qty / NULLIF(v.avg_daily_units, 0), 0) AS days_of_cover,
       CASE WHEN i.stock_qty = 0                    THEN 'OUT OF STOCK'
            WHEN i.stock_qty <= i.reorder_level     THEN 'REORDER NOW'
            WHEN i.stock_qty / NULLIF(v.avg_daily_units, 0) < 14 THEN 'WATCH'
            ELSE 'OK'
       END AS stock_status
FROM   inventory i
JOIN   products  p ON p.product_id = i.product_id
LEFT   JOIN velocity v ON v.product_id = i.product_id
WHERE  i.stock_qty <= i.reorder_level
   OR  i.stock_qty / NULLIF(v.avg_daily_units, 0) < 14
ORDER  BY days_of_cover NULLS FIRST;

-- ============================================================
-- Query 7: Pareto (ABC) Analysis of Product Revenue
-- Business question: What small share of products produces most of the revenue?
-- Technique: CTE + running-total window function
-- ============================================================
WITH prod_rev AS (
    SELECT p.product_id,
           p.product_name,
           SUM(oi.quantity * oi.unit_price * (1 - oi.discount)) AS revenue
    FROM   order_items oi
    JOIN   orders   o ON o.order_id   = oi.order_id
    JOIN   products p ON p.product_id = oi.product_id
    WHERE  o.status = 'COMPLETED'
      AND  o.order_date >= DATE '2025-01-01'
      AND  o.order_date <  DATE '2026-01-01'
    GROUP  BY p.product_id, p.product_name
),
ranked AS (
    SELECT *,
           SUM(revenue) OVER (ORDER BY revenue DESC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_rev,
           SUM(revenue) OVER ()                                                 AS total_rev
    FROM   prod_rev
)
SELECT product_id,
       product_name,
       ROUND(revenue, 0)                          AS revenue,
       ROUND(100.0 * running_rev / total_rev, 1)  AS cumulative_pct,
       CASE WHEN running_rev / total_rev <= 0.80 THEN 'A'
            WHEN running_rev / total_rev <= 0.95 THEN 'B'
            ELSE 'C' END                          AS abc_class
FROM   ranked
ORDER  BY revenue DESC;

-- ============================================================
-- Query 8: Market Basket Analysis (Products Bought Together)
-- Business question: Which pairs of products are most often bought in the same order?
-- Technique: Self-join + HAVING
-- ============================================================
SELECT pa.product_name AS product_a,
       pb.product_name AS product_b,
       COUNT(*)        AS orders_together
FROM   order_items a
JOIN   order_items b  ON  b.order_id   = a.order_id
                      AND a.product_id < b.product_id     -- each pair counted once
JOIN   orders      o  ON  o.order_id   = a.order_id
JOIN   products    pa ON  pa.product_id = a.product_id
JOIN   products    pb ON  pb.product_id = b.product_id
WHERE  o.status = 'COMPLETED'
  AND  o.order_date >= DATE '2025-01-01'
  AND  o.order_date <  DATE '2026-01-01'
GROUP  BY pa.product_name, pb.product_name
HAVING COUNT(*) >= 50
ORDER  BY orders_together DESC
LIMIT  10;
