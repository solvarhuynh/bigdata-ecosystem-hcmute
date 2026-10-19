# BigData Ecosystem HCMUTE

Cụm xử lý dữ liệu phân tán gồm một Master và tối đa bốn Worker, được đóng gói bằng
Docker. Hệ thống sử dụng Hadoop cho HDFS/YARN, Hive cho kho dữ liệu và Spark cho các
bài toán phân tích.

## Kiến trúc

- Master: NameNode, ResourceManager, Hive Metastore và HiveServer2.
- Worker: DataNode và NodeManager.
- Cấu hình local: một Master và một Worker trên cùng máy.
- Cấu hình triển khai: một Master và bốn Worker trên mạng LAN hoặc Tailscale.
- File `config/hadoop/workers` chỉ chứa các bí danh logic:

  ```text
  worker1
  worker2
  worker3
  worker4
  ```

Hostname thực tế và bí danh Hadoop là hai khái niệm độc lập. Ví dụ, Worker 1 có thể
dùng hostname `An-worker`, còn Hadoop vẫn kết nối tới bí danh `worker1`.

## Phiên bản

- Ubuntu 24.04 LTS
- OpenJDK 8
- Hadoop 3.4.0
- Apache Hive 3.1.3
- Apache Spark 3.5.1
- Docker Compose v2

## Yêu cầu

- Docker Engine hoặc Docker Desktop chạy Linux containers.
- Bash shell thông qua WSL, Git Bash hoặc Linux.
- Với triển khai nhiều máy: các máy phải truy cập được IP của nhau, phân giải được
  các bí danh logic và cho phép SSH trên cổng 22.
- Các cổng chính: 22, 8030-8033, 8088, 9000, 9870, 9083, 10000 và 10002.

## Cấu hình môi trường

Tạo file cấu hình riêng từ mẫu:

```bash
cp .env.example .env
```

Không commit `.env`. File này phải chứa IP thật của môi trường triển khai và hostname
thực tế của từng Worker. `.env.example` chỉ là mẫu không chứa bí mật.

Các biến quan trọng:

```dotenv
MASTER_IP=<IP-that-cua-Master>
WORKER1_IP=<IP-that-cua-Worker-1>
WORKER2_IP=<IP-that-cua-Worker-2>
WORKER3_IP=<IP-that-cua-Worker-3>
WORKER4_IP=<IP-that-cua-Worker-4>

NODE_HOSTNAME=An-worker
WORKER_LOGICAL_NAME=worker1
WORKER_IP=<IP-that-cua-An>

WORKER1_HOSTNAME=An-worker
WORKER2_HOSTNAME=Binh-slave
WORKER3_HOSTNAME=<hostname-worker-3>
WORKER4_HOSTNAME=<hostname-worker-4>
MASTER_HOSTNAME=nghia-master
```

Mỗi máy Worker thay `NODE_HOSTNAME`, `WORKER_LOGICAL_NAME` và `WORKER_IP` theo node
đó. Các biến `WORKERn_IP` và `WORKERn_HOSTNAME` phải nhất quán trên Master và tất cả
Worker.

## Build image

```bash
bash scripts/build_image.sh
```

Dockerfile hiển thị tiến độ tải các gói lớn, retry lỗi mạng tối đa năm lần, timeout kết
nối 30 giây và timeout tải 1.800 giây. Image mặc định là `bigdata-cluster:1.0`.

Để phân phối image cho các máy Worker:

```bash
bash scripts/export_image.sh
docker load -i bigdata-cluster-1.0.tar
```

## Khởi tạo và khởi động Master

NameNode không được format tự động. Chỉ khởi tạo lần đầu khi volume mới và thư mục
NameNode trống:

```bash
bash scripts/init_namenode.sh master
```

Nhập đúng chuỗi xác nhận mà script yêu cầu. Nếu volume đã có metadata, script sẽ từ
chối thao tác. Khi đó chỉ cần khởi động lại dịch vụ hiện có:

```bash
bash scripts/start_master.sh
```

`start_master.sh` không restart Master đang `running`. Nếu các dịch vụ bắt buộc đã sẵn
sàng, script báo thành công; nếu chưa sẵn sàng, script in trạng thái và log rồi trả mã
lỗi. Số lượng Worker được kiểm tra riêng bằng `check_cluster.sh`.

Khi đã build image mới và muốn áp dụng image cho container Master, dùng:

```powershell
docker compose -f docker/docker-compose.master.yml --env-file .env up -d --force-recreate master
```

Lệnh này có thể gây downtime trong thời gian container được thay mới nhưng không xóa
named volume `master_namenode` hoặc `master_hive_metastore`. Không sử dụng
`docker compose down -v`.

## Triển khai Worker

Trên mỗi máy Worker:

```bash
docker compose -f docker/docker-compose.worker.yml --env-file .env up -d
```

Sau khi khởi động đủ Worker, chạy trên Master:

```bash
bash scripts/check_cluster.sh full
```

Script hiển thị số DataNode và NodeManager kỳ vọng/thực tế. Script chờ SafeMode tối đa
120 giây; nếu SafeMode chưa tắt hoặc lệnh HDFS thất bại, script dừng trước khi tạo thư
mục HDFS.

## Chạy local

Mạng local dùng các IP bridge `172.20.0.2` và `172.20.0.3`. Đây là IP nội bộ cho thử
nghiệm trên một máy, không dùng cho triển khai LAN/Tailscale.

Khởi tạo local lần đầu:

```bash
bash scripts/init_namenode.sh local
bash scripts/test_local.sh
bash scripts/check_cluster.sh local
```

`test_local.sh` kiểm tra container Master và Worker cùng trạng thái `running` cũng như
các dịch vụ Master. `check_cluster.sh local` mới xác nhận DataNode và NodeManager.

## Hive

Hive Metastore dùng:

```xml
hive.metastore.port=9083
hive.metastore.uris=thrift://nghia-master:9083
```

Sau khi Master chạy, kiểm tra Metastore và HiveServer2:

```powershell
docker exec nghia-master bash -lc "ss -ltn | grep -E ':(9083|10000)\\s'"
docker exec nghia-master bash -lc "beeline -u 'jdbc:hive2://nghia-master:10000/default' -e 'show databases;'"
docker exec nghia-master bash -lc "tail -n 80 /opt/hive/logs/metastore.log /opt/hive/logs/hiveserver2.log"
```

## Kiểm tra cấu hình và phân giải tên

PowerShell:

```powershell
docker compose -f docker/docker-compose.local.yml config --quiet
docker compose --env-file .env -f docker/docker-compose.master.yml config --quiet
docker compose --env-file .env -f docker/docker-compose.worker.yml config --quiet
```

Kiểm tra bí danh logic và SSH từ Master:

```powershell
docker exec nghia-master bash -lc 'for n in worker1 worker2 worker3 worker4; do getent hosts "$n"; ssh -o BatchMode=yes -o ConnectTimeout=5 hadoopnghia@"$n" hostname; done'
```

Kiểm tra kết nối mạng từ Windows:

```powershell
Test-NetConnection <MASTER_IP> -Port 22
Test-NetConnection <MASTER_IP> -Port 9000
```

Docker Desktop Windows chạy container trong Linux VM. `network_mode: host` không tự
đồng nghĩa với mạng Windows host hoặc mạng Tailscale. Cần bật Linux containers, cấu
hình quyền truy cập VPN/WSL và firewall, sau đó kiểm tra kết nối thực tế giữa các máy.

## SSH và bảo mật

Image hiện tại tạo khóa SSH trong quá trình build để phục vụ môi trường học tập. Các
container dùng chung image có thể dùng chung bộ khóa; không sử dụng thiết kế này cho
môi trường production.

Môi trường production nên tạo khóa riêng khi khởi tạo từng node và chỉ phân phối public
key của Master tới `authorized_keys` của Worker bằng secret hoặc cơ chế mount được bảo
vệ.

## Cấu trúc thư mục

```text
config/       Cấu hình Hadoop, Hive và Spark
docker/       Dockerfile, entrypoint và Compose files
hive/         Hive SQL scripts
pyspark/      Các bài toán Spark
scripts/      Build, khởi tạo, khởi động và kiểm tra cụm
data/         Dữ liệu mẫu
```

## Bài thực hành

Sau khi cụm được kiểm tra bằng `check_cluster.sh`, có thể chạy trên Master:

```bash
hdfs dfs -put /opt/data/input_text_sample.txt /test_bigdata/input/
hdfs dfs -put /opt/data/sales_sample.csv /test_bigdata/hive_sales/

spark-submit --master yarn --deploy-mode client /opt/pyspark/word_count.py
spark-submit --master yarn --deploy-mode client /opt/pyspark/word_mean.py
spark-submit --master yarn --deploy-mode client /opt/pyspark/word_median.py
spark-submit --master yarn --deploy-mode client /opt/pyspark/word_std_dev.py

hive -f /opt/hive-scripts/01_create_warehouse.sql
hive -f /opt/hive-scripts/02_sales_analytics.sql
```
