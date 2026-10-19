-- 01_create_warehouse.sql
-- Tạo Database và Bảng External Warehouse cho dữ liệu bán hàng đồ án BigData-N14

CREATE DATABASE IF NOT EXISTS bigdata_n14_db;
USE bigdata_n14_db;

-- Tạo External Table trỏ vào thư mục HDFS /test_bigdata/hive_sales
CREATE EXTERNAL TABLE IF NOT EXISTS sales_warehouse (
    invoice_id STRING,
    branch STRING,
    city STRING,
    customer_type STRING,
    gender STRING,
    product_line STRING,
    unit_price DOUBLE,
    quantity INT,
    tax_5pct DOUBLE,
    total DOUBLE,
    sale_date STRING,
    sale_time STRING,
    payment STRING,
    cogs DOUBLE,
    gross_margin_pct DOUBLE,
    gross_income DOUBLE,
    rating DOUBLE
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '/test_bigdata/hive_sales'
TBLPROPERTIES ("skip.header.line.count"="1");