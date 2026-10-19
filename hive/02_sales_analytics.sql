-- 02_sales_analytics.sql
-- Các truy vấn phân tích bán hàng trên Hive Data Warehouse
USE bigdata_n14_db;

-- 1. Thống kê tổng doanh thu và số lượng đơn hàng theo từng Thành phố (City)
SELECT
    city,
    COUNT(invoice_id) AS total_orders,
    ROUND(SUM(total), 2) AS total_revenue,
    ROUND(AVG(rating), 2) AS avg_rating
FROM sales_warehouse
GROUP BY city
ORDER BY total_revenue DESC;

-- 2. Thống kê tổng doanh thu theo Phương thức thanh toán (Payment)
SELECT
    payment,
    COUNT(invoice_id) AS transaction_count,
    ROUND(SUM(total), 2) AS total_spent
FROM sales_warehouse
GROUP BY payment
ORDER BY total_spent DESC;

-- 3. Thống kê doanh thu và lợi nhuận theo Nhóm sản phẩm (Product Line)
SELECT
    product_line,
    SUM(quantity) AS total_quantity_sold,
    ROUND(SUM(total), 2) AS total_revenue,
    ROUND(SUM(gross_income), 2) AS total_gross_income
FROM sales_warehouse
GROUP BY product_line
ORDER BY total_revenue DESC;
