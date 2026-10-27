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

### Kiểm tra các file đầu vào/đầu ra trên HDFS

```powershell
docker exec -u hadoopnghia nghia-master hdfs dfs -ls -R /nhom14/input
```

```powershell
docker exec -u hadoopnghia nghia-master hdfs dfs -ls -R /nhom14/output
```

## 4. Khởi động và chạy Spark

Kiến trúc hiện tại chạy ứng dụng bằng `spark-submit` từ Master ở chế độ YARN client; repository không yêu cầu chạy `start-spark.sh`. Các script được mount vào `/opt/pyspark`. Mỗi lệnh dưới đây chạy đồng bộ trong cửa sổ PowerShell và trả mã thoát của `spark-submit`; chạy từng bài, đợi lệnh kết thúc rồi mới chạy bài tiếp theo.

### WordCount

```powershell
docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_count.py"
```

Kết quả dự kiến: in đường dẫn HDFS đầu vào, tiêu đề kết quả WordCount và các từ cùng số lần xuất hiện, sắp xếp giảm dần theo số lần. Script mặc định đọc `hdfs:///nhom14/input/word/description.txt`.

### Word Length Mean

```powershell
docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_mean.py"
```

Kết quả dự kiến: tổng số từ, tổng số ký tự và độ dài từ trung bình (hiển thị 4 chữ số thập phân). Script mặc định đọc `hdfs:///nhom14/input/word/description.txt`.

### Word Length Median

```powershell
docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_median.py"
```

Kết quả dự kiến: tổng số từ, độ dài ở vị trí giữa và giá trị trung vị độ dài từ. Nếu không có từ trong dữ liệu, script in thông báo tương ứng rồi kết thúc.

### Word Length Standard Deviation

```powershell
docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_std_dev.py"
```

Kết quả dự kiến: tổng số từ, độ dài trung bình, phương sai và độ lệch chuẩn độ dài từ (các giá trị số hiển thị 4 chữ số thập phân). Nếu không có từ trong dữ liệu, script in thông báo tương ứng rồi kết thúc.

```powershell
docker exec -u hadoopnghia nghia-master yarn application -list -appStates ALL
```

## 5. Giao diện theo dõi trên trình duyệt

Theo `.env`, máy Master có địa chỉ `MASTER_IP=100.75.213.56`. Docker Compose publish các cổng giao diện vào địa chỉ này, vì vậy không dùng `localhost`.

- **HDFS NameNode:** [http://100.75.213.56:9870](http://100.75.213.56:9870) — xem DataNode, dung lượng HDFS và block dữ liệu.
- **YARN ResourceManager:** [http://100.75.213.56:8088/cluster](http://100.75.213.56:8088/cluster) — xem application, trạng thái YARN và các node thực thi.
- **Spark Web UI:** [http://100.75.213.56:4040](http://100.75.213.56:4040) — mở khi bài Spark đang chạy, sau đó chọn tab Executors để xem host và task.


```powershell
docker build -f .\docker\Dockerfile -t bigdata-cluster:1.0 .
docker compose --env-file .env -f .\docker\docker-compose.master.yml up -d --force-recreate master
```

> Máy đang mở trình duyệt phải truy cập được mạng Tailscale và cho phép kết nối tới `100.75.213.56`. Nếu muốn kiểm tra nhanh trên PowerShell: `Test-NetConnection 100.75.213.56 -Port 8088` và `Test-NetConnection 100.75.213.56 -Port 9870`.

## 6. Lưu kết quả Hive và Spark vào thư mục `output`

### Chuẩn bị

```powershell
if (-not (Test-Path -LiteralPath .\.env)) {
    throw 'Hay chay lenh tu thu muc goc D:\BigData-N14.'
}

$OutputDir = Join-Path (Get-Location).Path 'output'
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$SessionLog = Join-Path $OutputDir 'session.txt'

docker exec -u hadoopnghia nghia-master hdfs dfs -mkdir -p /nhom14/output
if ($LASTEXITCODE -ne 0) {
    throw "Khong tao duoc thu muc HDFS /nhom14/output; exit code $LASTEXITCODE"
}

$HiveSqlCount = 'SELECT COUNT(*) AS total_rows FROM online_retail;'
$HiveSqlCountry = @'
SET dfs.client.use.datanode.hostname=true;
SELECT country, COUNT(DISTINCT invoice) AS total_invoices,
       SUM(CAST(quantity AS BIGINT)) AS net_quantity,
       ROUND(SUM(CAST(quantity AS DOUBLE) * CAST(price AS DOUBLE)), 2) AS net_revenue
FROM online_retail
WHERE invoice IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL
GROUP BY country
ORDER BY net_revenue DESC
LIMIT 10;
'@
$HiveSqlProducts = @'
SET dfs.client.use.datanode.hostname=true;
SELECT stockcode, MAX(description) AS product_description,
       SUM(CAST(quantity AS BIGINT)) AS total_quantity,
       ROUND(SUM(CAST(quantity AS DOUBLE) * CAST(price AS DOUBLE)), 2) AS total_revenue
FROM online_retail
WHERE stockcode IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL
GROUP BY stockcode
ORDER BY total_revenue DESC
LIMIT 20;
'@
$HiveSqlInvoices = @'
SET dfs.client.use.datanode.hostname=true;
SELECT invoice,
       ROUND(SUM(CAST(quantity AS DOUBLE) * CAST(price AS DOUBLE)), 2) AS invoice_total
FROM online_retail
WHERE invoice IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL
GROUP BY invoice
ORDER BY invoice_total DESC
LIMIT 20;
'@

function Invoke-N14Task {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$HdfsFile,
        [Parameter(Mandatory=$true)][string]$LocalFile,
        [Parameter(Mandatory=$true)][scriptblock]$Command
    )

    $StageFile = Join-Path ([System.IO.Path]::GetTempPath()) $HdfsFile
    Start-Transcript -Path $SessionLog -Append | Out-Null
    try {
        Write-Host "`n=== $Name ==="
        $CapturedOutput = @()
        & $Command 2>&1 | Tee-Object -Variable CapturedOutput
        $ExitCode = $LASTEXITCODE
        if ($ExitCode -ne 0) {
            throw "$Name failed with exit code $ExitCode"
        }

        $TextLines = [string[]]@($CapturedOutput | ForEach-Object { [string]$_ })
        [System.IO.File]::WriteAllLines(
            $StageFile,
            $TextLines,
            [System.Text.UTF8Encoding]::new($false)
        )

        docker cp $StageFile "nghia-master:/tmp/$HdfsFile"
        if ($LASTEXITCODE -ne 0) {
            throw "Khong copy duoc output tam vao container; exit code $LASTEXITCODE"
        }

        docker exec -u hadoopnghia nghia-master hdfs dfs -put -f "/tmp/$HdfsFile" "/nhom14/output/$HdfsFile"
        if ($LASTEXITCODE -ne 0) {
            throw "Khong ghi duoc /nhom14/output/$HdfsFile len HDFS; exit code $LASTEXITCODE"
        }

        docker exec -u hadoopnghia nghia-master hdfs dfs -get -f "/nhom14/output/$HdfsFile" "/tmp/$($HdfsFile).from_hdfs"
        if ($LASTEXITCODE -ne 0) {
            throw "Khong tai duoc /nhom14/output/$HdfsFile tu HDFS; exit code $LASTEXITCODE"
        }

        docker cp "nghia-master:/tmp/$($HdfsFile).from_hdfs" $LocalFile
        if ($LASTEXITCODE -ne 0) {
            throw "Khong xuat duoc file HDFS ve $LocalFile; exit code $LASTEXITCODE"
        }

        Write-Host "Da luu HDFS: /nhom14/output/$HdfsFile"
        Write-Host "Da xuat local: $LocalFile"
    }
    finally {
        Stop-Transcript | Out-Null
        if (Test-Path -LiteralPath $StageFile) {
            Remove-Item -LiteralPath $StageFile -Force
        }
    }
}
```

### Chạy riêng từng bài

Chỉ gọi lệnh của bài cần lưu. Mỗi lệnh kết thúc rồi mới chạy lệnh kế tiếp nếu muốn lưu thêm bài khác.

Hive — Phân tích 0, đếm số dòng:

```powershell
Invoke-N14Task -Name 'Hive 0 - COUNT(*)' -HdfsFile 'hive_00_count.txt' -LocalFile (Join-Path $OutputDir 'hive_00_count.txt') -Command {
    docker exec -u hadoopnghia nghia-master /opt/hive/bin/beeline -u 'jdbc:hive2://nghia-master:10000/bigdata_n14_db' -e $HiveSqlCount
}
```

Hive — Phân tích 1, doanh thu theo quốc gia:

```powershell
Invoke-N14Task -Name 'Hive 1 - Country revenue' -HdfsFile 'hive_01_country.txt' -LocalFile (Join-Path $OutputDir 'hive_01_country.txt') -Command {
    docker exec -u hadoopnghia nghia-master /opt/hive/bin/beeline -u 'jdbc:hive2://nghia-master:10000/bigdata_n14_db' -e $HiveSqlCountry
}
```

Hive — Phân tích 2, top 20 sản phẩm:

```powershell
Invoke-N14Task -Name 'Hive 2 - Top products' -HdfsFile 'hive_02_products.txt' -LocalFile (Join-Path $OutputDir 'hive_02_products.txt') -Command {
    docker exec -u hadoopnghia nghia-master /opt/hive/bin/beeline -u 'jdbc:hive2://nghia-master:10000/bigdata_n14_db' -e $HiveSqlProducts
}
```

Hive — Phân tích 3, top 20 hóa đơn:

```powershell
Invoke-N14Task -Name 'Hive 3 - Top invoices' -HdfsFile 'hive_03_invoices.txt' -LocalFile (Join-Path $OutputDir 'hive_03_invoices.txt') -Command {
    docker exec -u hadoopnghia nghia-master /opt/hive/bin/beeline -u 'jdbc:hive2://nghia-master:10000/bigdata_n14_db' -e $HiveSqlInvoices
}
```

WordCount:

```powershell
Invoke-N14Task -Name 'Spark WordCount' -HdfsFile 'spark_01_word_count.txt' -LocalFile (Join-Path $OutputDir 'spark_01_word_count.txt') -Command {
    docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_count.py"
}
```

Word Length Mean:

```powershell
Invoke-N14Task -Name 'Spark Word Length Mean' -HdfsFile 'spark_02_word_mean.txt' -LocalFile (Join-Path $OutputDir 'spark_02_word_mean.txt') -Command {
    docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_mean.py"
}
```

Word Length Median:

```powershell
Invoke-N14Task -Name 'Spark Word Length Median' -HdfsFile 'spark_03_word_median.txt' -LocalFile (Join-Path $OutputDir 'spark_03_word_median.txt') -Command {
    docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_median.py"
}
```

Word Length Standard Deviation:

```powershell
Invoke-N14Task -Name 'Spark Word Length Standard Deviation' -HdfsFile 'spark_04_word_std_dev.txt' -LocalFile (Join-Path $OutputDir 'spark_04_word_std_dev.txt') -Command {
    docker exec -u hadoopnghia nghia-master bash -lc "spark-submit --master yarn --deploy-mode client --conf spark.hadoop.dfs.client.use.datanode.hostname=true --conf spark.python.use.daemon=true /opt/pyspark/word_std_dev.py"
}
```

Mỗi lệnh ở trên chạy đúng một bài. Output gốc của bài được giữ trên màn hình; khi lệnh thành công, cùng nội dung được ghi vào file HDFS và tải về file local tương ứng. Nếu bài lỗi, hàm giữ mã thoát và dừng trước khi xuất file như kết quả thành công. `session.txt` ghi lại các lần gọi hàm và được nối thêm, không dùng timestamp.

### Liệt kê nội dung `/nhom14/output` trên HDFS

```powershell
docker exec -u hadoopnghia nghia-master hdfs dfs -ls -R /nhom14/output
```

Các file local được tải từ `/nhom14/output`; chạy lại một bài sẽ ghi đè file cùng tên ở cả hai nơi.



---

```
docker exec nghia-master bash -lc 'for h in worker1 worker2 worker3 worker4; do echo "===== $h ====="; getent hosts "$h"; for p in 8041 8042 9864 9866 9867 19868 19888; do if timeout 3 bash -c "echo > /dev/tcp/$h/$p" 2>/dev/null; then echo "$h:$p OPEN"; else echo "$h:$p FAIL"; fi; done; done'
```