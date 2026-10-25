
-- 01_create_warehouse.sql
-- BigData-N14: Hive External Table cho Online Retail

CREATE DATABASE IF NOT EXISTS bigdata_n14_db;
USE bigdata_n14_db;

-- Bảng phân tích dữ liệu Online Retail
CREATE EXTERNAL TABLE IF NOT EXISTS online_retail (
    invoice STRING,
    stockcode STRING,
    description STRING,
    quantity STRING,
    invoicedate STRING,
    price STRING,
    customer_id STRING,
    country STRING
)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar' = '"',
    'escapeChar' = '\\'
)
STORED AS TEXTFILE
LOCATION '/nhom14/input/hive_sales'
TBLPROPERTIES (
    'skip.header.line.count' = '1'
);
