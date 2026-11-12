-- schema.sql : virtual retail database (PostgreSQL 14+)
CREATE TABLE categories (
    category_id    SERIAL PRIMARY KEY,
    category_name  TEXT NOT NULL UNIQUE
);

CREATE TABLE products (
    product_id     TEXT PRIMARY KEY,
    product_name   TEXT NOT NULL,
    category_id    INT  NOT NULL REFERENCES categories(category_id),
    unit_cost      NUMERIC(10,2) NOT NULL,
    unit_price     NUMERIC(10,2) NOT NULL
);

CREATE TABLE customers (
    customer_id    TEXT PRIMARY KEY,
    customer_name  TEXT NOT NULL,
    city           TEXT,
    signup_date    DATE NOT NULL
);

CREATE TABLE orders (
    order_id       BIGSERIAL PRIMARY KEY,
    customer_id    TEXT NOT NULL REFERENCES customers(customer_id),
    order_date     DATE NOT NULL,
    status         TEXT NOT NULL CHECK (status IN ('COMPLETED','CANCELLED','RETURNED'))
);

CREATE TABLE order_items (
    order_item_id  BIGSERIAL PRIMARY KEY,
    order_id       BIGINT NOT NULL REFERENCES orders(order_id),
    product_id     TEXT   NOT NULL REFERENCES products(product_id),
    quantity       INT    NOT NULL CHECK (quantity > 0),
    unit_price     NUMERIC(10,2) NOT NULL,
    discount       NUMERIC(4,3)  NOT NULL DEFAULT 0   -- 0.10 = 10% off
);

CREATE TABLE inventory (
    product_id     TEXT PRIMARY KEY REFERENCES products(product_id),
    stock_qty      INT NOT NULL,
    reorder_level  INT NOT NULL,
    last_updated   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE inventory_snapshots (          -- one row per product per day
    snapshot_date  DATE NOT NULL,
    product_id     TEXT NOT NULL REFERENCES products(product_id),
    stock_qty      INT  NOT NULL,
    PRIMARY KEY (snapshot_date, product_id)
);

-- Supporting indexes for reporting queries
CREATE INDEX idx_orders_completed_date
    ON orders (order_date) INCLUDE (customer_id)
    WHERE status = 'COMPLETED';                       -- partial: smaller, cheaper writes

CREATE INDEX idx_items_order_cover
    ON order_items (order_id) INCLUDE (product_id, quantity, unit_price, discount);

CREATE INDEX idx_items_product ON order_items (product_id);
CREATE INDEX idx_products_category ON products (category_id);

-- 1) Parameterised report: one function, many reports
CREATE OR REPLACE FUNCTION sales_report(
    p_start    DATE,
    p_end      DATE,
    p_category TEXT DEFAULT NULL          -- NULL = all categories
)
RETURNS TABLE (category_name TEXT, orders BIGINT, units BIGINT, revenue NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT c.category_name,
           COUNT(DISTINCT o.order_id),
           SUM(oi.quantity),
           ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount)), 2)
    FROM   orders o
    JOIN   order_items oi ON oi.order_id   = o.order_id
    JOIN   products    p  ON p.product_id  = oi.product_id
    JOIN   categories  c  ON c.category_id = p.category_id
    WHERE  o.status = 'COMPLETED'
      AND  o.order_date >= p_start
      AND  o.order_date <  p_end + 1
      AND  (p_category IS NULL OR c.category_name = p_category)
    GROUP  BY c.category_name
    ORDER  BY 4 DESC;
$$;

-- Usage
SELECT * FROM sales_report('2025-10-01', '2025-12-31');                -- all categories
SELECT * FROM sales_report('2025-10-01', '2025-12-31', 'Electronics'); -- one category

-- 2) Pre-aggregated daily summary for dashboards
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT o.order_date                                     AS sales_date,
       p.category_id,
       COUNT(DISTINCT o.order_id)                       AS orders,
       SUM(oi.quantity)                                 AS units,
       SUM(oi.quantity * oi.unit_price * (1 - oi.discount)) AS revenue
FROM   orders o
JOIN   order_items oi ON oi.order_id  = o.order_id
JOIN   products    p  ON p.product_id = oi.product_id
WHERE  o.status = 'COMPLETED'
GROUP  BY o.order_date, p.category_id
WITH DATA;

-- Required for REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX ux_mv_daily_sales ON mv_daily_sales (sales_date, category_id);

-- 3) Refresh log so every dashboard can show "data as of ..."
CREATE TABLE mv_refresh_log (
    mv_name      TEXT NOT NULL,
    refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    duration_ms  INT
);

CREATE OR REPLACE PROCEDURE refresh_mv_daily_sales()
LANGUAGE plpgsql AS $$
DECLARE t0 TIMESTAMPTZ := clock_timestamp();
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;
    INSERT INTO mv_refresh_log (mv_name, duration_ms)
    VALUES ('mv_daily_sales',
            (EXTRACT(EPOCH FROM clock_timestamp() - t0) * 1000)::int);
END $$;

-- Schedule every 15 minutes (pg_cron extension)
SELECT cron.schedule('refresh_mv_daily_sales', '*/15 * * * *',
                     'CALL refresh_mv_daily_sales()');

-- Staleness check
SELECT mv_name,
       MAX(refreshed_at)         AS last_refresh,
       now() - MAX(refreshed_at) AS staleness
FROM   mv_refresh_log
GROUP  BY mv_name;
