
-- 02_sales_analytics.sql
-- Phân tích dữ liệu Online Retail trên Hive

USE bigdata_n14_db;

-- 1. Tổng số hóa đơn, số lượng sản phẩm và doanh thu theo quốc gia
SELECT
    country,
    COUNT(DISTINCT invoice) AS total_invoices,
    SUM(CAST(quantity AS INT)) AS total_quantity,
    ROUND(
        SUM(CAST(quantity AS INT) * CAST(price AS DOUBLE)), 2
    ) AS total_revenue
FROM online_retail
WHERE invoice IS NOT NULL
  AND quantity IS NOT NULL
  AND price IS NOT NULL
GROUP BY country
ORDER BY total_revenue DESC;

-- 2. Thống kê số lượng bán và doanh thu theo mã sản phẩm
SELECT
    stockcode,
    MAX(description) AS product_description,
    SUM(CAST(quantity AS INT)) AS total_quantity,
    ROUND(
        SUM(CAST(quantity AS INT) * CAST(price AS DOUBLE)), 2
    ) AS total_revenue
FROM online_retail
WHERE stockcode IS NOT NULL
  AND quantity IS NOT NULL
  AND price IS NOT NULL
GROUP BY stockcode
ORDER BY total_revenue DESC
LIMIT 20;

-- 3. Thống kê doanh thu theo hóa đơn
SELECT
    invoice,
    COUNT(*) AS line_items,
    SUM(CAST(quantity AS INT)) AS total_quantity,
    ROUND(
        SUM(CAST(quantity AS INT) * CAST(price AS DOUBLE)), 2
    ) AS invoice_revenue
FROM online_retail
WHERE invoice IS NOT NULL
  AND quantity IS NOT NULL
  AND price IS NOT NULL
GROUP BY invoice
ORDER BY invoice_revenue DESC
LIMIT 20;
