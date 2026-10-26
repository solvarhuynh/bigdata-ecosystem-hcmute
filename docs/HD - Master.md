# Master

## 1. Khởi động container của toàn cụm

### Bước 1 — Trên máy Master

```powershell
docker compose --env-file .env -f .\docker\docker-compose.master.yml up -d
```

Lệnh này khởi động container Master.
`entrypoint.sh` khởi động các dịch vụ gồm HDFS NameNode, YARN ResourceManager, Hive Metastore và HiveServer2.

### Bước 2 — Trên từng máy Worker

```powershell
docker compose --env-file .env -f .\docker\docker-compose.worker.yml up -d
```

## 2. Kiểm tra HDFS và YARN

### Kiểm tra tiến trình:

```powershell
docker exec nghia-master bash -lc "jps"
```

### Kiểm tra HDFS:

```powershell
docker exec -u hadoopnghia nghia-master hdfs dfsadmin -report
docker exec -u hadoopnghia nghia-master hdfs dfsadmin -safemode get
```

### Kiểm tra các Worker đăng ký với YARN:

```powershell
docker exec -u hadoopnghia nghia-master yarn node -list -all
```

## Chỉ khởi động thủ công nếu xác nhận daemon đang thiếu

Trên `Master`, chỉ chạy nếu `jps` xác nhận NameNode chưa hoạt động:

```powershell
docker exec -u hadoopnghia nghia-master hdfs --daemon start namenode
```

Trên Master, chỉ chạy nếu `ResourceManager` chưa hoạt động:

```powershell
docker exec -u hadoopnghia nghia-master yarn --daemon start resourcemanager
```
--- 

Trên chính `máy Worker` bị thiếu `DataNode`. Ví dụ máy Khang:

```powershell
docker exec -u hadoopnghia khang-worker hdfs --daemon start datanode
```

Trên chính máy Worker bị thiếu `NodeManager`:

```powershell
docker exec -u hadoopnghia khang-worker yarn --daemon start nodemanager
```

## 3. Khởi động và kiểm tra Hive

Trên Master:

```powershell
docker exec nghia-master bash -lc "bash /start_hive_services.sh"
```

Kiểm tra ba cổng dịch vụ:

```powershell
docker exec nghia-master bash -lc 'for p in 9083 10000 10002; do if (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null; then echo "$p OPEN"; else echo "$p CLOSED"; fi; done'
```

Kiểm tra truy vấn thực tế bằng Beeline:

```powershell
docker exec -u hadoopnghia nghia-master bash -lc "/opt/hive/bin/beeline -u 'jdbc:hive2://nghia-master:10000/bigdata_n14_db' -e 'SHOW DATABASES;'"
```

Nếu `entrypoint.sh` đã tự khởi động Hive và cả ba cổng đang mở, không cần gọi lại script. Chạy `start_hive_services.sh` khi Hive chưa hoạt động hoặc cần khởi động lại theo quy trình của dự án. 

## Phân tích 0 - Đếm số dòng

```powershell
docker exec -u hadoopnghia nghia-master bash -lc "/opt/hive/bin/beeline -u 'jdbc:hive2://nghia-master:10000/bigdata_n14_db' -e 'SELECT COUNT(*) AS total_rows FROM online_retail;'"
```

## Phân tích 1 — Doanh thu theo quốc gia

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -e 'SET dfs.client.use.datanode.hostname=true; SELECT country, COUNT(DISTINCT invoice) AS total_invoices, SUM(CAST(quantity AS BIGINT)) AS net_quantity, ROUND(SUM(CAST(quantity AS DOUBLE) * CAST(price AS DOUBLE)), 2) AS net_revenue FROM online_retail WHERE invoice IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL GROUP BY country ORDER BY net_revenue DESC LIMIT 10;'"
```

**Ý nghĩa:** Tổng hợp số hóa đơn khác nhau, số lượng ròng và doanh thu ròng theo quốc gia; hiển thị 10 quốc gia đứng đầu theo doanh thu.

## Phân tích 2 — Top 20 sản phẩm theo doanh thu

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -e 'SET dfs.client.use.datanode.hostname=true; SELECT stockcode, MAX(description) AS product_description, SUM(CAST(quantity AS BIGINT)) AS total_quantity, ROUND(SUM(CAST(quantity AS DOUBLE) * CAST(price AS DOUBLE)), 2) AS total_revenue FROM online_retail WHERE stockcode IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL GROUP BY stockcode ORDER BY total_revenue DESC LIMIT 20;'"
```

**Ý nghĩa:** Tổng hợp số lượng và doanh thu theo mã sản phẩm; hiển thị 20 mã có doanh thu cao nhất.

## Phân tích 3 — Top 20 hóa đơn có giá trị lớn nhất

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -e 'SET dfs.client.use.datanode.hostname=true; SELECT invoice, ROUND(SUM(CAST(quantity AS DOUBLE) * CAST(price AS DOUBLE)), 2) AS invoice_total FROM online_retail WHERE invoice IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL GROUP BY invoice ORDER BY invoice_total DESC LIMIT 20;'"
```

**Ý nghĩa:** Tổng hợp doanh thu theo hóa đơn và hiển thị 20 hóa đơn có giá trị lớn nhất.


## 4. Khởi động và chạy Spark

Không cần chạy `start-spark.sh` trong kiến trúc hiện tại. Lệnh chạy ứng dụng là `spark-submit`.

Tạo hàm PowerShell ngay trong cửa sổ đang dùng trên Master để dùng lại các tùy chọn IPv4 đã được sử dụng khi kiểm thử liên máy:

```powershell
function Run-SparkTest {
    param([Parameter(Mandatory=$true)][string]$ScriptName)

    $cmd = "spark-submit --master yarn --deploy-mode client --conf spark.driver.host=100.75.213.56 --conf spark.driver.bindAddress=0.0.0.0 --conf spark.driver.extraJavaOptions=-Djava.net.preferIPv4Stack=true --conf spark.executor.extraJavaOptions=-Djava.net.preferIPv4Stack=true --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=false /opt/pyspark/$ScriptName"

    docker exec -u hadoopnghia nghia-master bash -lc $cmd
}
```

Chạy từng bài một và đợi bài trước kết thúc:

```powershell
Run-SparkTest word_count.py
Run-SparkTest word_mean.py
Run-SparkTest word_median.py
Run-SparkTest word_std_dev.py
```

## 5. Giao diện theo dõi trên trình duyệt

- **HDFS NameNode:** [http://localhost:9870](http://localhost:9870) — xem DataNode, dung lượng HDFS và block dữ liệu.
- **YARN ResourceManager:** [http://localhost:8088](http://localhost:8088) — xem application, trạng thái YARN và các node thực thi.
- **Spark Web UI:** [http://localhost:4040](http://localhost:4040) — mở khi bài Spark đang chạy, sau đó chọn tab Executors để xem host và task. UI thường không tồn tại sau khi ứng dụng kết thúc.

