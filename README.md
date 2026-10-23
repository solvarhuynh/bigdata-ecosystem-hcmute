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
- Cổng Master: 22, 7078-7095, 8030-8033, 8088, 9000, 9870, 9083, 10000 và 10002.
- Cổng Worker: 22, 8040-8042, 9864, 9866, 9867 và 13562. Chỉ cho phép lưu lượng
  cần thiết giữa các IP Tailscale của các node.

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
Worker. Mỗi máy dùng `.env` riêng với IP, hostname thực tế và bí danh logic của Worker
tương ứng; không cần biến SSH runtime.

## Cấu hình và đăng ký DataNode

`config/hadoop/hdfs-site.xml` là cấu hình HDFS dùng chung cho Master, Worker và local
Compose. Worker Compose bắt buộc nhận đủ `NODE_HOSTNAME`, `WORKER_LOGICAL_NAME`,
`WORKER_IP`, `MASTER_IP` cùng mapping `WORKER1_*` đến `WORKER4_*`; thiếu biến thì
`docker compose config` dừng thay vì tạo đường dẫn cấu hình sai. Ví dụ, máy có hostname
`An-worker` được phân công alias `worker1` sẽ có `NODE_HOSTNAME=An-worker`,
`WORKER_LOGICAL_NAME=worker1`, `WORKER_IP` bằng địa chỉ IPv4 của máy đó,
`WORKER1_HOSTNAME=An-worker` và `WORKER1_IP` bằng cùng địa chỉ IP.

Khi khởi động Worker, entrypoint sao chép cấu hình Hadoop vào
`/tmp/bigdata-hadoop-conf`, chỉ bổ sung `dfs.datanode.hostname` từ `NODE_HOSTNAME`, rồi
kiểm tra cấu hình hiệu lực trước khi chạy daemon. `dfs.datanode.address=0.0.0.0:9866`
là địa chỉ bind trong container, không phải địa chỉ có thể truy cập từ LAN/Tailscale.
Alias `workerN` và hostname thực tế cùng được ánh xạ tới IP cấu hình. Worker chỉ báo
đăng ký thành công khi NameNode nhìn thấy hostname đó qua endpoint không phải loopback;
script cũng chờ NodeManager đăng ký với ResourceManager.

`dfs.client.use.datanode.hostname=true` và
`dfs.datanode.use.datanode.hostname=true` yêu cầu client/DataNode tự phân giải hostname;
chúng không biến `127.0.0.1` thành địa chỉ mạng có thể định tuyến. Trong
`hdfs dfsadmin -report`, từng Worker phải có hostname khác nhau, endpoint `Name` khác
nhau và không phải loopback. `scripts/check_cluster.sh full` kiểm tra số lượng, endpoint,
hostname DataNode cùng NodeManager, đồng thời đối chiếu IP endpoint `Name` với IP Worker
đã cấu hình trước khi kiểm tra HDFS/Hive.

Xem cấu hình runtime ngay trên máy Worker:

```powershell
docker exec --user hadoopnghia bigdata-worker1 env HADOOP_CONF_DIR=/tmp/bigdata-hadoop-conf /opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.hostname
docker exec --user hadoopnghia bigdata-worker1 env HADOOP_CONF_DIR=/tmp/bigdata-hadoop-conf /opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.address
docker exec --user hadoopnghia bigdata-worker1 env HADOOP_CONF_DIR=/tmp/bigdata-hadoop-conf /opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.use.datanode.hostname
```

## Build image

```bash
bash scripts/build_image.sh
```

Dockerfile hiển thị tiến độ tải các gói lớn, retry lỗi mạng tối đa năm lần, timeout kết
nối 30 giây và timeout tải 1.800 giây. Image mặc định là `bigdata-cluster:1.0`.
Các Compose file mount `docker/entrypoint.sh` từ source và gọi qua Bash, nên các thay đổi
entrypoint không cần build lại image; cần recreate container để áp dụng Compose/mount mới.
`config/spark/spark-defaults.conf` được COPY vào image, vì vậy thay đổi cấu hình Spark cần
build lại image, phân phối cùng image đó cho các máy và recreate Master. `yarn-site.xml`
được bind-mount; thay đổi cấu hình này cần recreate Master và Worker để daemon nạp lại.

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

Khi chỉ cập nhật entrypoint hoặc cấu hình đã bind-mount từ repository, áp dụng bằng cách
recreate container tương ứng. Thao tác có thể gây downtime nhưng không xóa named volume:

```powershell
docker compose -f docker/docker-compose.master.yml --env-file .env up -d --force-recreate master
docker compose -f docker/docker-compose.worker.yml --env-file .env up -d --force-recreate worker
docker compose -f docker/docker-compose.local.yml up -d --force-recreate
```

Không dùng `docker compose down -v`.

Master sẵn sàng ở bước đầu khi NameNode, ResourceManager và Metastore hoạt động. HiveServer2
được khởi chạy nhưng có thể chưa mở cổng JDBC khi HDFS còn SafeMode; HiveServer2 sẽ thử lại
sau khi Worker đăng ký. `start_master.sh` chỉ xác nhận các dịch vụ cốt lõi của Master, không
xác nhận HiveServer2 hoặc toàn bộ cluster.

## Triển khai Worker

Trên mỗi máy Worker:

```bash
docker compose --env-file .env -f docker/docker-compose.worker.yml config --quiet
docker compose --env-file .env -f docker/docker-compose.worker.yml up -d --force-recreate worker
```

Chỉ rollout từng Worker sau khi mapping được xác nhận. Recreate gây downtime cho Worker
đó nhưng giữ named volume; không chạy lệnh xóa volume.

Sau khi khởi động đủ Worker, chạy trên Master:

```bash
bash scripts/check_cluster.sh full
```

Script hiển thị số DataNode và NodeManager kỳ vọng/thực tế. Script chờ SafeMode tối đa
120 giây; nếu SafeMode chưa tắt hoặc lệnh HDFS thất bại, script dừng trước khi tạo thư
mục HDFS. Nó cũng yêu cầu input `/test_bigdata/input/description.txt` tồn tại và không rỗng.

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
NameNode, ResourceManager và Metastore. Sau đó `check_cluster.sh local` kiểm tra đủ
DataNode/NodeManager, chờ SafeMode tắt, tạo các thư mục HDFS cần thiết và kiểm tra HiveServer2
bằng truy vấn JDBC `SHOW DATABASES`.

## Hive

Hive Metastore dùng:

```xml
hive.metastore.port=9083
hive.metastore.uris=thrift://nghia-master:9083
```

Sau khi Worker đã đăng ký và `check_cluster.sh local` hoặc `check_cluster.sh full` hoàn tất,
kiểm tra Metastore và HiveServer2:

```powershell
docker exec nghia-master bash -lc "netstat -lnt | grep -E ':(9083|10000)\\s'"
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

Kiểm tra bí danh logic và SSH từ Master (thực hiện với user Hadoop đã được cấp key):

```powershell
docker exec --user hadoopnghia nghia-master bash -lc 'for n in worker1 worker2 worker3 worker4; do getent hosts "$n"; ssh -o BatchMode=yes -o ConnectTimeout=5 hadoopnghia@"$n" hostname; done'
```

Kiểm tra kết nối mạng từ Windows:

```powershell
Test-NetConnection <MASTER_IP> -Port 22
Test-NetConnection <MASTER_IP> -Port 9000
```

Docker Desktop Windows chạy container trong Linux VM. `network_mode: host` không tự
đồng nghĩa với mạng Windows host hoặc mạng Tailscale. Docker Desktop 4.34 trở lên yêu cầu
đăng nhập, bật Settings > Resources > Network > Enable host networking rồi Apply & restart.
Tính năng chỉ áp dụng cho Linux containers, hoạt động ở layer 4 (TCP/UDP), không cho
container bind trực tiếp vào IP của host và không tương thích Enhanced Container Isolation.
Cấu hình local dùng bridge nên không chứng minh host networking hay kết nối Tailscale liên
máy. Trước khi triển khai hàng loạt, thử một Worker và xác minh endpoint DataNode trong
NameNode report là duy nhất, không loopback, cùng với kết nối TCP qua địa chỉ mạng thực tế.
Nếu endpoint còn trùng/loopback, dừng rollout và chọn lại giữa host networking đã kiểm
chứng, bridge kèm port publishing đầy đủ, hoặc runtime/host khác.
Bridge + publish chưa được cấu hình vì cần kiểm thử cả HDFS, YARN, shuffle và Spark,
không chỉ cổng DataNode. Xem [Hadoop 3.4.0 HDFS multihoming](https://hadoop.apache.org/docs/r3.4.0/hadoop-project-dist/hadoop-hdfs/HdfsMultihoming.html),
[Docker host network driver](https://docs.docker.com/engine/network/drivers/host/) và
[Docker Desktop networking](https://docs.docker.com/desktop/features/networking/).

Các phương án mạng cho triển khai nhiều máy:

- `network_mode: host` (Compose hiện tại): dùng cùng namespace mạng của container host.
  Trên Docker Desktop cần bản 4.34 trở lên, đăng nhập và bật host networking; container
  không có IP riêng, không bind trực tiếp được vào interface Tailscale của Windows và
  chỉ hỗ trợ lưu lượng TCP/UDP. Việc Compose khai báo host mode không chứng minh NameNode
  nhận được địa chỉ DataNode có thể định tuyến qua Tailscale.
- Bridge kèm publish: có port forwarding rõ ràng, nhưng phải publish và kiểm tra đầu-cuối
  các cổng HDFS (Master RPC 9000; Worker DataNode 9866, HTTP 9864, IPC 9867), YARN
  (Master 8030-8033; Worker 8040-8042 và shuffle 13562), NameNode/RM web 9870/8088,
  Hive 9083/10000/10002, SSH 22 nếu dùng, và Spark driver/block-manager 7078-7095.
  Host-port và container-port của DataNode phải thống nhất với endpoint Hadoop quảng bá;
  Docker Desktop mặc định publish trên mọi interface nên cần kiểm tra khả năng giới hạn
  interface/firewall trên từng máy.
- Runtime khác: Docker Engine native Linux hoặc host/container runtime có địa chỉ được
  định tuyến rõ ràng có thể tránh lớp mạng Docker Desktop, nhưng cần thử cùng cổng, DNS,
  Tailscale và firewall thực tế trước khi chọn.

Chưa chọn hoặc triển khai network model mới: cần kiểm tra TCP hai chiều giữa các máy và
đối chiếu log runtime của Worker. Xác minh một Worker trước; nếu endpoint NameNode còn
loopback/trùng, dừng rollout và quyết định phương án mạng sau khi đo kết quả. Không xem
DNS/`getent` là bằng chứng TCP/Tailscale hoạt động.

Sau khi duyệt source/image, trên từng Worker kiểm tra Compose rồi recreate riêng service
để áp dụng cấu hình mới. Thao tác gây downtime cho Worker đó nhưng giữ named volume nếu
không dùng lệnh xóa volume:

```powershell
docker compose --env-file .env -f docker/docker-compose.worker.yml config --quiet
docker compose --env-file .env -f docker/docker-compose.worker.yml up -d --force-recreate worker
```

Sau khi một Worker khởi động, kiểm tra `docker logs bigdata-worker1`; từ Master chạy
`bash scripts/check_cluster.sh full` sau khi các Worker dự kiến đã lên. Nếu DataNode
endpoint trùng/loopback hoặc đăng ký timeout, dừng rollout và gửi log cùng HDFS report;
không xóa volume, format NameNode hoặc xóa dữ liệu.

Spark chạy ở client mode. Driver quảng bá bí danh `nghia-master` (được entrypoint ánh xạ
tới `MASTER_IP` trên mỗi node), bind trên mọi interface và dùng TCP 7078. BlockManager
dùng 7079-7095 để các tiến trình executor trên cùng máy có thể chọn cổng kế tiếp khi cần.
Cho phép TCP 7078-7095 giữa Master và Worker, giới hạn nguồn vào các peer Tailscale.
NodeManager RPC được cố định ở TCP 8041. Trước khi cố định, local YARN đã đăng ký trên
cổng động. Sau khi áp dụng cấu hình mới, kiểm tra node list để xác nhận Worker báo cổng
8041; cần recreate Worker để nạp cấu hình mới.

## SSH cho môi trường đồ án

Docker image tạo một SSH client key cho user `hadoopnghia` khi build và cài public key
vào `authorized_keys` của cùng user. Các node dùng chung image nên dùng cùng client key.
Host-key verification được tắt để đơn giản hóa môi trường lab; chỉ dùng trong mạng đồ án,
không dùng key này cho tài khoản cá nhân, máy chủ bên ngoài hoặc dữ liệu nhạy cảm.

Entry point tạo SSH server host key khi khởi động `sshd`. Khởi động lại cùng container
giữ host key; recreate container có thể tạo host key mới. Hadoop daemon trong entrypoint
được khởi động trực tiếp bằng `hdfs --daemon` và `yarn --daemon`, không cần SSH để bootstrap
local mode. Cơ chế SSH vẫn có sẵn cho lệnh quản trị/kiểm tra liên node.

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

Sau khi Master và các Worker đã khởi động, chạy `check_cluster.sh` để xác nhận node,
SafeMode, input và Hive JDBC. Nếu script báo thiếu input, kiểm tra file nguồn và HDFS path;
script đã tạo thư mục đích. Chỉ nạp khi xác nhận file đích chưa tồn tại; `-put` không ghi đè:

```powershell
# Chỉ chạy dòng upload nếu HDFS file thực sự chưa tồn tại.
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfs -test -s /test_bigdata/input/description.txt"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfs -put /opt/data/description.txt /test_bigdata/input/description.txt"
```

Nếu `-test -s` thất bại nhưng file đích vẫn có trong `hdfs dfs -ls`, không upload đè; hãy
kiểm tra file đó thủ công. Sau khi nạp input còn thiếu, chạy lại `check_cluster.sh` rồi mới
chạy Spark. Bốn bài Spark chỉ đọc input trên HDFS và in kết quả ra driver:

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_count.py"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_mean.py"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_median.py"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_std_dev.py"
```

Sales analytics chỉ chạy sau khi đã xác minh dữ liệu CSV 17 cột được nạp vào
`/test_bigdata/hive_sales`. File `data/online_retail.csv` hiện có 8 cột, không tương thích
với DDL trong `hive/01_create_warehouse.sql`.

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/default -f /opt/hive-scripts/01_create_warehouse.sql"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -f /opt/hive-scripts/02_sales_analytics.sql"
```
