# BigData Ecosystem HCMUTE

Cụm xử lý dữ liệu phân tán gồm một Master và tối đa bốn Worker, được đóng gói bằng
Docker. Hệ thống sử dụng Hadoop cho HDFS/YARN, Hive cho kho dữ liệu và Spark cho các
bài toán phân tích.

## Kiến trúc

- Master: NameNode và ResourceManager trong deployment phase `core`; Hive Metastore và
  HiveServer2 được khởi động sau pilot health gate. Local Compose dùng phase `full`.
- Worker: DataNode và NodeManager.
- Cấu hình local: một Master và một Worker trên cùng máy.
- Cấu hình triển khai dự kiến: một Master và bốn Worker qua địa chỉ có thể định tuyến
  giữa các máy. Tailscale/Docker Desktop chưa được kiểm thử đầu-cuối trong repository này.
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
- Với triển khai nhiều máy: các máy phải truy cập được địa chỉ của nhau, phân giải được
  hostname DataNode và bí danh logic, đồng thời cho phép đúng các cổng cần thiết.
- Cổng Master: 22, 7078-7095, 8030-8033, 8088, 9000, 9870, 9083, 10000 và 10002.
- Cổng Worker: 22, 7079-7095 (Spark BlockManager), 8040-8042, 9864, 9867, 13562,
  41000-41099 (MapReduce AM client RPC), 41100-41149 (MapReduce AM web UI) và cổng
  DataNode transfer riêng theo Worker (mặc định 19866-19869). Compose publish các cổng
  này riêng lên `WORKER_IP`; giới hạn Windows Defender Firewall theo peer cần thiết và
  không mở chúng ra Internet công cộng.

## Cấu hình môi trường

Tạo file cấu hình riêng từ mẫu:

```bash
cp .env.example .env
```

Không commit `.env`. File này phải chứa IP thật của môi trường triển khai và hostname
thực tế của từng Worker. `.env.example` chỉ là mẫu không chứa bí mật.

Các biến quan trọng:

```dotenv
MASTER_START_PHASE=core
MASTER_IP=<IP-that-cua-Master>
WORKER1_IP=<IP-that-cua-Worker-1>
WORKER2_IP=<IP-that-cua-Worker-2>
WORKER3_IP=<IP-that-cua-Worker-3>
WORKER4_IP=<IP-that-cua-Worker-4>
WORKER1_XFER_PORT=19866
WORKER2_XFER_PORT=19867
WORKER3_XFER_PORT=19868
WORKER4_XFER_PORT=19869

NODE_HOSTNAME=An-worker
WORKER_LOGICAL_NAME=worker1
WORKER_IP=<IP-that-cua-An>
WORKER_XFER_PORT=19866

WORKER1_HOSTNAME=An-worker
WORKER2_HOSTNAME=Binh-slave
WORKER3_HOSTNAME=<hostname-worker-3>
WORKER4_HOSTNAME=<hostname-worker-4>
MASTER_HOSTNAME=nghia-master
```

Deployment Compose forwards `MASTER_START_PHASE` into the Master container and defaults to
`core`; leave `.env` at `core` for the staged rollout below. Local Compose sets
`MASTER_START_PHASE=full` directly in its Master service, so its phase does not depend on the
host `.env` value.

Mỗi máy Worker thay `NODE_HOSTNAME`, `WORKER_LOGICAL_NAME`, `WORKER_IP` và
`WORKER_XFER_PORT` theo node đó. Các biến `WORKERn_IP`, `WORKERn_HOSTNAME` và
`WORKERn_XFER_PORT` phải nhất quán trên Master và tất cả
Worker. Mỗi máy dùng `.env` riêng với IP, hostname thực tế và bí danh logic của Worker
tương ứng; tên container triển khai cũng chính là `NODE_HOSTNAME` (ví dụ
`khang-worker`), không dùng tiền tố `bigdata-`. Không cần biến SSH runtime.

## Cấu hình và đăng ký DataNode

`config/hadoop/hdfs-site.xml` là cấu hình HDFS dùng chung cho Master, Worker và local
Compose. Worker Compose bắt buộc nhận đủ `NODE_HOSTNAME`, `WORKER_LOGICAL_NAME`,
`WORKER_IP`, `MASTER_IP` cùng mapping `WORKER1_*` đến `WORKER4_*`; thiếu biến thì
`docker compose config` dừng thay vì tạo đường dẫn cấu hình sai. Ví dụ, máy có hostname
`An-worker` được phân công alias `worker1` sẽ có `NODE_HOSTNAME=An-worker`,
`WORKER_LOGICAL_NAME=worker1`, `WORKER_IP` bằng địa chỉ IPv4 của máy đó,
`WORKER1_HOSTNAME=An-worker`, `WORKER1_IP` bằng cùng địa chỉ IP và
`WORKER_XFER_PORT=WORKER1_XFER_PORT=19866`. Các cổng `WORKERn_XFER_PORT` phải khác
nhau; Compose publish cùng cổng trên host và trong container.

Khi khởi động Worker, entrypoint sao chép cấu hình Hadoop vào
`/tmp/bigdata-hadoop-conf`, đặt `dfs.datanode.hostname` từ `NODE_HOSTNAME` và
`dfs.datanode.address=0.0.0.0:$WORKER_XFER_PORT`, rồi kiểm tra cấu hình hiệu lực trước
khi chạy daemon. `dfs.datanode.address` là địa chỉ bind trong container, không phải
địa chỉ có thể truy cập từ LAN/Tailscale.
Trên Master và các Worker khác, bí danh `workerN` cùng hostname thực tế được ánh xạ tới
`WORKERn_IP`. Bên trong mỗi Worker, entrypoint lấy IPv4 hiện có của container từ
`hostname -I` và chỉ ánh xạ bí danh logic của chính node đó tới địa chỉ bridge này. Nhờ vậy,
Spark YARN Executor dùng được địa chỉ thuộc network namespace của container để bind, trong khi
Master và Worker khác vẫn phân giải hostname quảng bá `workerN` tới IP host đã cấu hình.
Hostname DataNode thực tế phân giải tới `WORKERn_IP` trên các node còn lại; nếu hostname thực tế
trùng bí danh logic, tên đó phân giải tới bridge IP bên trong chính Worker và tới `WORKERn_IP`
ở các node khác.

Runtime Hadoop config của Worker giữ NodeManager identity ổn định bằng cách đặt
`yarn.nodemanager.hostname` và `yarn.nodemanager.address` theo bí danh logic, đồng thời bind
RPC tới `0.0.0.0`; Web UI NodeManager cũng quảng bá bí danh logic. Worker chỉ báo đăng ký thành
công khi NameNode thấy hostname DataNode qua endpoint mới, không-loopback, và ResourceManager
thấy NodeManager dưới đúng bí danh. Endpoint `Name` trong HDFS report không bị giả định phải
bằng `WORKER_IP`; cần kiểm tra endpoint thực tế, hostname mapping và khả năng truy cập riêng.

Sau khi rollout một Worker, đối chiếu phân giải ngay trên Worker và Master. Trên Worker, bí danh
của chính nó phải trả về IPv4 trong `hostname -I`, và reverse lookup của IPv4 đó phải trả
`workerN` làm tên đầu tiên; trên Master, cùng bí danh phải trả về `WORKERn_IP`. `yarn node
-list -all` trên Master phải tiếp tục hiển thị NodeManager dưới `workerN`.

Với Hadoop 3.4.0, NameNode thay IP trong đăng ký bằng địa chỉ nguồn của kết nối RPC. Trên
Docker Desktop các Worker có thể cùng xuất hiện với IP NAT của Docker; Hadoop cũng loại
DataNode cũ nếu một đăng ký khác dùng cùng cặp IP/transfer-port. Vì vậy mỗi bí danh Worker
có transfer port riêng (19866-19869 mặc định), còn hostname thực tế tiếp tục là địa chỉ
client/peer dùng khi hostname mode bật. `dfs.namenode.datanode.registration.ip-hostname-check=false`
chỉ bỏ kiểm tra phân giải IP/hostname, không giữ lại IP DataNode tự quảng bá; cấu hình này
được giữ để chấp nhận NAT hostname mismatch, còn tính duy nhất được bảo đảm bằng transfer
port. Đây là giải pháp phù hợp theo mã nguồn Hadoop 3.4.0, chưa phải xác nhận runtime trên
Docker Desktop/Tailscale. Xem [logic đăng ký DataNode trong Hadoop 3.4.0](https://github.com/apache/hadoop/blob/rel/release-3.4.0/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeManager.java#L1159-L1203).

`dfs.client.use.datanode.hostname=true` và
`dfs.datanode.use.datanode.hostname=true` khiến HDFS client/DataNode phân giải hostname
được báo cáo để truyền block; chúng không chứng minh endpoint `Name` thực tế có thể truy cập.
Trong `hdfs dfsadmin -report`, endpoint phải duy nhất và không-loopback, hostname mỗi Worker
phải đúng và có capacity/block report. `scripts/check_cluster.sh local|pilot|full` kiểm tra hostname
phân giải tới IP đã cấu hình, TCP tới transfer port gán cho từng Worker, NodeManager RUNNING
và HDFS fsck.
Các kiểm tra này chưa chứng minh được Tailscale/Docker Desktop hoạt động cho tới khi script
được chạy trên cluster thật.
Việc tách transfer port không thay đổi volume hay thư mục DataNode. `Configured Capacity: 0`
hoặc `Last Block Report: Never` là lỗi trạng thái lưu trữ/report riêng; health gate sẽ dừng,
cần xem DataNode log, mount và quyền đọc/ghi thay vì format hoặc xóa metadata.

Registration freshness so sánh thời điểm DataNode bắt đầu với `Last contact` do NameNode báo,
nên đồng hồ Windows trên Master và Worker phải được đồng bộ. Trên từng máy, kiểm tra trước khi
khởi động:

```powershell
Get-Date -Format o
w32tm /query /status
```

Xem cấu hình runtime ngay trên máy Worker:

```powershell
docker exec --user hadoopnghia khang-worker env HADOOP_CONF_DIR=/tmp/bigdata-hadoop-conf /opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.hostname
docker exec --user hadoopnghia khang-worker env HADOOP_CONF_DIR=/tmp/bigdata-hadoop-conf /opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.address
docker exec --user hadoopnghia khang-worker env HADOOP_CONF_DIR=/tmp/bigdata-hadoop-conf /opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.use.datanode.hostname
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
`scripts/start_hive_services.sh` được bind-mount chỉ đọc vào Master; đổi script cần recreate
Master để cập nhật bản mount.

Để phân phối image cho các máy Worker:

```bash
bash scripts/export_image.sh
docker load -i bigdata-cluster-1.0.tar
```

## Triển khai theo giai đoạn

### 1. Master core

Deployment Compose mặc định đặt `MASTER_START_PHASE=core`: chỉ NameNode và ResourceManager
được khởi động, không chờ DataNode count và không tự khởi động Hive. Trước khi áp dụng
Compose lên container Master hiện có, kiểm tra volume đang mount:

```powershell
docker inspect nghia-master --format '{{range .Mounts}}{{println .Name .Destination}}{{end}}'
docker volume inspect docker_local_namenode docker_local_hive_metastore
docker compose --env-file .env -f docker/docker-compose.master.yml config --quiet
```

Chỉ tiếp tục khi NameNode đang dùng đúng volume `docker_local_namenode`. Nếu volume/mount
khác hoặc không xác định được, dừng để điều tra; không format hoặc đổi volume. Nếu NameNode
đã có metadata, khởi động Master bằng `bash scripts/start_master.sh`. Script không restart
container đang chạy; chỉ báo PASS khi container hiện tại, NameNode, ResourceManager và
readiness marker của đúng lần khởi động đã sẵn sàng.

Đảm bảo `.env` đặt `MASTER_START_PHASE=core`. Giá trị trong `.env` không đổi environment của
container đang chạy; kiểm tra phase hiện tại bằng `docker exec nghia-master printenv MASTER_START_PHASE`.
Nếu container cũ đang dùng phase khác, sau khi xác nhận đúng named volume hãy áp dụng cấu hình
bằng lệnh sau. Thao tác này gây downtime nhưng không xóa external named volume. Nếu container đã
ở phase `core` và sẵn sàng, `start_master.sh` giữ nguyên container.

```powershell
docker compose --env-file .env -f docker/docker-compose.master.yml up -d --force-recreate master
```

Nếu NameNode chưa có metadata, không format khi chưa xác nhận volume mới và trống. Dùng quy
trình khởi tạo riêng `bash scripts/init_namenode.sh master` chỉ sau khi kiểm tra volume và
thư mục đích. Entry point không format NameNode.

### 2. Worker 1 — Khang, rồi Worker 3 — Hồng Khoa

Mỗi máy dùng `.env` riêng. Với Khang, đặt `NODE_HOSTNAME=khang-worker`,
`WORKER_LOGICAL_NAME=worker1`, `WORKER_IP` bằng `WORKER1_IP`; với Hồng Khoa đặt
`NODE_HOSTNAME=hongkhoa-worker`, `WORKER_LOGICAL_NAME=worker3`, `WORKER_IP` bằng
`WORKER3_IP`. Đặt lần lượt `WORKER_XFER_PORT=19866` và `WORKER_XFER_PORT=19868`;
các worker còn lại dùng 19867 và 19869. Hostname thực tế do nhóm chọn; bí danh Hadoop
giữ nguyên `worker1`/`worker3` và không đổi `config/hadoop/workers`.

Trên từng Worker, trước mỗi recreate, xác nhận container hiện tại đang mount đúng DataNode
volume tại `/opt/hadoop/hdfs/datanode`. So sánh tên volume thực tế với Compose project/volume
mong muốn; nếu không có container cũ hoặc không xác định được volume chứa metadata, dừng và
xác minh thủ công trước khi tạo/recreate. Không xóa volume.

Trên máy Khang, chạy lần lượt:

```powershell
$composeJson = docker compose --env-file .env -f docker/docker-compose.worker.yml config --format json
if ($LASTEXITCODE -ne 0) { throw 'Không render được Worker Compose; dừng rollout.' }
$composeConfig = ConvertFrom-Json -InputObject ($composeJson -join [Environment]::NewLine)
$expectedDnVolume = $composeConfig.volumes.worker_datanode.name
$dnVolume = docker inspect khang-worker --format '{{range .Mounts}}{{if eq .Destination "/opt/hadoop/hdfs/datanode"}}{{.Name}}{{end}}{{end}}'
if ($LASTEXITCODE -ne 0 -or -not $dnVolume) { throw 'Không tìm thấy container hoặc DataNode volume mount hiện tại; dừng rollout.' }
if (-not $expectedDnVolume -or $dnVolume -ne $expectedDnVolume) { throw "Container đang mount '$dnVolume' nhưng Compose sẽ dùng '$expectedDnVolume'; dừng để xác minh volume/project." }
docker volume inspect $expectedDnVolume
docker compose --env-file .env -f docker/docker-compose.worker.yml up -d --force-recreate worker
docker logs khang-worker --tail 120
```

Chờ log xác nhận DataNode registration cho hostname `khang-worker` và NodeManager alias
`worker1`. Chỉ sau đó chuyển sang máy Hồng Khoa; kiểm tra volume của node đó riêng rồi mới
recreate:

```powershell
$composeJson = docker compose --env-file .env -f docker/docker-compose.worker.yml config --format json
if ($LASTEXITCODE -ne 0) { throw 'Không render được Worker Compose; dừng rollout.' }
$composeConfig = ConvertFrom-Json -InputObject ($composeJson -join [Environment]::NewLine)
$expectedDnVolume = $composeConfig.volumes.worker_datanode.name
$dnVolume = docker inspect hongkhoa-worker --format '{{range .Mounts}}{{if eq .Destination "/opt/hadoop/hdfs/datanode"}}{{.Name}}{{end}}{{end}}'
if ($LASTEXITCODE -ne 0 -or -not $dnVolume) { throw 'Không tìm thấy container hoặc DataNode volume mount hiện tại; dừng rollout.' }
if (-not $expectedDnVolume -or $dnVolume -ne $expectedDnVolume) { throw "Container đang mount '$dnVolume' nhưng Compose sẽ dùng '$expectedDnVolume'; dừng để xác minh volume/project." }
docker volume inspect $expectedDnVolume
docker compose --env-file .env -f docker/docker-compose.worker.yml up -d --force-recreate worker
docker logs hongkhoa-worker --tail 120
```

Chờ NodeManager alias `worker3` và DataNode `hongkhoa-worker` được xác nhận; không chạy hai
recreate đồng thời.

Từ Master, sau khi cả hai Worker đã khởi động, chạy pilot:

```bash
bash scripts/check_cluster.sh pilot
```

Pilot yêu cầu đúng 2 Live DataNodes (slots 1 và 3), 2 NodeManagers RUNNING dưới alias
`worker1`/`worker3`, endpoint duy nhất/non-loopback, hostname/IP mapping, TCP transfer
port theo mapping (19866 và 19868), capacity > 0, block report, SafeMode OFF và `fsck /`
không có block thiếu/hỏng. Pilot chỉ
đọc trạng thái và không tạo thư mục/đổi quyền HDFS. Nếu SafeMode không tắt hoặc fsck fail,
dừng rollout; không force SafeMode OFF và không chạy Hive/Spark.

### 3. Khởi động Hive sau pilot

Chỉ sau khi `check_cluster.sh pilot` PASS, chạy helper bên trong Master đang chạy:

```powershell
docker exec nghia-master bash /start_hive_services.sh
```

Compose bind-mount script chỉ đọc từ `scripts/start_hive_services.sh` tới
`/start_hive_services.sh` trong Master. Helper đọc `javax.jdo.option.ConnectionURL` từ
`/opt/hive/conf/hive-site.xml`; cấu hình hiện tại trỏ Derby tới
`/opt/hive/metastore_db/metastore_db`, bên trong named-volume mount
`/opt/hive/metastore_db`. Script từ chối nếu URL không phải embedded Derby hoặc mount
không khớp đường dẫn cấu hình. Nó kiểm tra NameNode/ResourceManager, đợi SafeMode OFF,
chạy bounded read-only `fsck /`, rồi mới thay đổi working directory/quyền HDFS.

Metastore mount mới và hoàn toàn trống mới được `schematool -initSchema`. Mount không rỗng
chỉ được nhận dạng là Derby hiện có khi đúng thư mục cấu hình chứa `service.properties`
không rỗng; trường hợp này được giữ nguyên và không chạy schema init. Đây là nhận dạng
marker filesystem, không phải xác minh schema hoặc tính toàn vẹn Derby; Hive startup và JDBC
`SHOW DATABASES` mới là kiểm tra runtime. Mount không rỗng nhưng không nhận dạng được bị từ
chối để kiểm tra thủ công. Helper chờ cổng 9083/10000 và kiểm tra JDBC. Nó không format
NameNode, xóa dữ liệu hoặc volume.

### 4. Spark sau Hive

Chỉ chạy Spark sau khi pilot health gate và helper Hive đều PASS. Dùng các lệnh
`spark-submit --master yarn --deploy-mode client` trong mục [Bài thực hành](#bài-thực-hành).
Pilot không chạy workload và không xác nhận Spark; nếu HDFS/fsck hoặc Hive JDBC thất bại thì
dừng trước bước này.

## Áp dụng image/source đã thay đổi

Sau khi build image mới và kiểm tra mount volumes, áp dụng image cho Master bằng:

```powershell
docker compose --env-file .env -f docker/docker-compose.master.yml up -d --force-recreate master
```

Lệnh có thể gây downtime cho NameNode/ResourceManager nhưng không xóa named volume. Việc
container đang tồn tại không đảm bảo image mới được dùng nếu không recreate. Các Worker chỉ
recreate riêng lẻ sau khi đã xác nhận volume mount như bước 2. Không dùng
`docker compose down -v`.

## Chạy local

Local Compose giữ bridge test riêng (`172.20.0.2` Master, `172.20.0.3` Worker) và đặt
`MASTER_START_PHASE=full` để khởi động Hive tự động sau khi local HDFS vượt qua SafeMode/fsck
gate. Local Master nhận giá trị `full` từ `environment` trong Compose; sửa biến cùng tên ở
`.env` không đổi phase local. Các IP bridge này chỉ dùng trong Compose local.

```bash
# Chỉ chạy một lần khi volume NameNode mới đã được xác nhận trống.
bash scripts/init_namenode.sh local
# Với volume đã khởi tạo, bỏ qua lệnh init và chỉ chạy hai lệnh sau.
bash scripts/test_local.sh
bash scripts/check_cluster.sh local
```

Không chạy lại `init_namenode.sh` trên volume đã có metadata. Nếu script từ chối vì thư mục
NameNode không trống, dừng và kiểm tra thủ công; không xóa metadata hay volume để làm bước init
qua.

`test_local.sh` xác nhận Master/Worker containers đang running cùng các cổng dịch vụ Master;
nó không thay cho kiểm tra DataNode, NodeManager, SafeMode, fsck hoặc Hive JDBC. Bước tiếp theo
`check_cluster.sh local` kiểm tra các dịch vụ đó, đồng thời giữ các thao tác tạo thư mục/quyền
HDFS hiện có sau khi health/fsck gate đạt.

## Hive

Hive Metastore dùng `hive.metastore.port=9083` và
`hive.metastore.uris=thrift://nghia-master:9083`. Sau khi pilot pass, chạy helper ở bước 3;
không suy ra Metastore/HiveServer2 sẵn sàng chỉ từ XML hợp lệ hoặc cổng đã khai báo.

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
$masterIp = Read-Host 'Nhập MASTER_IP (IPv4 Tailscale)'
$workerIp = Read-Host 'Nhập WORKER1_IP (IPv4 Tailscale)'
$workerXferPort = 19866
Test-NetConnection -ComputerName $masterIp -Port 9000
Test-NetConnection -ComputerName $workerIp -Port $workerXferPort
Test-NetConnection -ComputerName $workerIp -Port 8041
```

Kiểm tra hostname mapping trong Master (đối chiếu mỗi kết quả với IP Tailscale trong `.env`):

```powershell
docker exec nghia-master bash -lc 'for n in worker1 worker2 worker3 worker4; do getent ahostsv4 "$n"; done'
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfsadmin -report"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn node -list -all"
```

`getent` chỉ xác nhận mapping trong container. `scripts/check_cluster.sh pilot` kiểm tra
worker1/worker3 trước Hive; `full` dành cho cả bốn Worker và Hive JDBC.
Không có kết quả runtime nào xác nhận Tailscale/Docker Desktop trong lần rà soát này.

Compose triển khai hiện dùng bridge network và publish các host port của Master/Worker.
Đây mới là cấu hình ứng viên để kiểm thử, chưa phải xác nhận mạng Tailscale hoạt động.
Trên Docker Desktop, port publishing được chuyển tiếp qua backend của Docker vào Linux VM;
tài liệu Docker không xác nhận địa chỉ DataNode mà Hadoop sẽ báo trong topology Tailscale này.
Phải xác minh endpoint thực tế trong `hdfs dfsadmin -report`; không suy ra endpoint từ
`WORKER_IP`, DNS hay dòng log DataNode.

Entrypoint đặt `dfs.datanode.address=0.0.0.0:$WORKER_XFER_PORT` bên trong container.
`dfs.datanode.hostname` là hostname mà DataNode báo; hai tùy chọn
`dfs.client.use.datanode.hostname` và `dfs.datanode.use.datanode.hostname` yêu cầu client/peer
phân giải hostname cho luồng dữ liệu, nhưng không thay thế việc xác minh endpoint trong HDFS
report và luồng dữ liệu thật. Compose publish cùng transfer port trên host Worker và trong
container. HDFS report có thể hiện cùng IP NAT Docker cho nhiều Worker, nhưng cặp IP/port
phải duy nhất; client/peer dùng hostname thực tế cùng transfer port để tới host qua mạng đã cấu hình.

Compose bind host ports vào đúng địa chỉ `MASTER_IP`/`WORKER_IP` đã cấu hình. Các địa chỉ này
phải là IP Tailscale của host nhận port forwarding, không phải IP bridge của container.
Trước khi chạy, cấu hình Windows Defender Firewall trên từng máy chỉ cho phép nguồn là các
IP Tailscale của Master/Worker và các cổng nêu ở trên; không mở các cổng này cho profile
mạng công cộng. Cổng 22 cũng được publish nhưng image chứa client private key dùng chung và
tắt SSH host-key verification; SSH hiện không được xem là an toàn.
Không dùng image này cho mạng hoặc tài khoản ngoài lab.

Docker Desktop host networking không được Compose triển khai hiện tại sử dụng. Nếu thử riêng,
cần Docker Desktop 4.34 trở lên, đăng nhập, bật Settings > Resources > Network > Enable host
networking rồi Apply & restart. Tính năng chỉ hỗ trợ Linux containers, TCP/UDP ở layer 4,
không cho process trong container bind trực tiếp vào IP interface của host và không tương
thích Enhanced Container Isolation. Bật host networking cũng không chứng minh được Tailscale
reachability hoặc khả năng truy cập tới endpoint DataNode.

Bridge + published ports có thể expose dịch vụ qua host nhưng không tự tạo Docker overlay
network giữa các Docker Desktop độc lập. Nếu endpoint DataNode được báo thành loopback hoặc bị trùng,
dừng rollout. Một Docker Engine Linux/VM có Tailscale và địa chỉ routable là phương án khác
cần đánh giá riêng; không đổi Docker context/engine khi chưa xác minh named volume và kế hoạch
bảo toàn metadata.

Triển khai Worker theo từng máy và theo thứ tự ở phần “Triển khai theo giai đoạn”; kiểm tra
mount volume trước mỗi recreate. Nếu endpoint trùng/loopback, capacity 0, block report Never
hoặc registration timeout, dừng rollout; không xóa volume, format NameNode, đổi replication
factor hay xóa dữ liệu. Lịch sử log được cung cấp từng báo 179 missing blocks; trạng thái
hiện tại chỉ có thể xác nhận bằng `fsck /` trên cụm thật.

Spark chạy ở client mode. Driver quảng bá bí danh `nghia-master` (được entrypoint ánh xạ
tới `MASTER_IP` trên mỗi node), bind trên mọi interface và dùng TCP 7078. Executor
BlockManager bắt đầu ở 7079 và có tối đa 16 lần thử lại, nên Worker publish dải
7079-7095. Cho phép TCP 7078-7095 giữa Master và Worker, và dải BlockManager giữa các
Worker executor cần trao đổi dữ liệu; giới hạn nguồn vào các peer tin cậy.
NodeManager RPC được cố định ở TCP 8041. Trước khi cố định, local YARN đã đăng ký trên
cổng động. Sau khi áp dụng cấu hình mới, kiểm tra node list để xác nhận Worker báo cổng
8041; cần recreate Worker để nạp cấu hình mới.

## Theo dõi HDFS, YARN và Spark

Trên máy Master mở NameNode UI tại `http://<MASTER_IP>:9870` và ResourceManager UI tại
`http://<MASTER_IP>:8088`. `localhost` chỉ phù hợp trên chính máy Master nếu host-port đó
được bind vào loopback; máy khác phải dùng địa chỉ routable đã publish (`MASTER_IP`).

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfsadmin -report"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn node -list -all"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn application -list -appStates ALL"
$appId = Read-Host 'YARN application ID'
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn application -status $appId"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn applicationattempt -list $appId"
$attemptId = Read-Host 'YARN application attempt ID'
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn container -list $attemptId"
$containerId = Read-Host 'YARN container ID'
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn container -status $containerId"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn logs -applicationId $appId -containerId $containerId"
```

`spark-submit` chạy ở client mode nên driver output và application ID xuất hiện trong cửa sổ
đã chạy lệnh. Dùng chuỗi lệnh trên để lần từ application tới attempt, container và NodeManager;
`yarn container -status` cho biết node của container. Có thể đối chiếu thêm trong RM UI và
NodeManager UI tại `http://<WORKER_IP>:8042`. `yarn logs` có thể không lấy được log của ứng dụng
đã kết thúc vì cấu hình hiện tại chưa bật YARN log aggregation; khi đó kiểm tra container qua
NodeManager UI hoặc log cục bộ của Worker. Chưa có runtime test xác nhận các đường dẫn log.

Sau mỗi Spark job, đối chiếu tên application, trạng thái YARN, node allocations và kết quả
được in trong terminal driver. Bốn bài word processing không ghi output HDFS; không chạy
chúng nếu pilot/fsck chưa pass hoặc HDFS input chưa được xác nhận.

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

Chỉ bắt đầu sau `check_cluster.sh pilot` PASS, Hive helper hoàn tất và `fsck /` không báo
missing/corrupt blocks. Trước Spark xác nhận input `/nhom14/input/word/description.txt`;
nguồn mẫu là `/opt/data/description.txt` trên Master. Các lệnh dưới đây kiểm tra thư mục
và file trước khi upload; nếu đích đã tồn tại thì không ghi đè.

```powershell
$wordPath = '/nhom14/input/word/description.txt'
docker exec nghia-master su hadoopnghia -s /bin/bash -c '/opt/hadoop/bin/hdfs dfs -ls /nhom14/input/word'
if ($LASTEXITCODE -ne 0) { throw 'Không xác minh được HDFS input directory.' }
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfs -test -e $wordPath"
$wordTest = $LASTEXITCODE
if ($wordTest -eq 0) {
    'Input đã tồn tại; bỏ qua upload và không ghi đè.'
} elseif ($wordTest -eq 1) {
    docker exec nghia-master su hadoopnghia -s /bin/bash -c 'test -s /opt/data/description.txt'
    if ($LASTEXITCODE -ne 0) { throw 'File nguồn description.txt không tồn tại hoặc rỗng.' }
    docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfs -put /opt/data/description.txt $wordPath"
    if ($LASTEXITCODE -ne 0) { throw 'Upload thất bại; giữ nguyên dữ liệu hiện tại.' }
} else { throw 'Lỗi khi kiểm tra đích HDFS; không upload.' }
```

Xác nhận input khác rỗng và khỏe mạnh trước khi submit:

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c '/opt/hadoop/bin/hdfs dfs -test -s /nhom14/input/word/description.txt'
if ($LASTEXITCODE -ne 0) { throw 'HDFS word input không tồn tại hoặc rỗng; dừng trước Spark.' }
$wordFsck = docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 120s /opt/hadoop/bin/hdfs fsck /nhom14/input/word/description.txt -files -blocks -locations' 2>&1
$wordFsckExit = $LASTEXITCODE
$wordFsck
$wordFsckText = $wordFsck -join "`n"
if ($wordFsckExit -ne 0 -or $wordFsckText -match '(?im)Status:\s*CORRUPT|MISSING BLOCKS:?[ \t]*[1-9][0-9]*|CORRUPT BLOCKS:?[ \t]*[1-9][0-9]*') { throw 'Word input fsck failed or found missing/corrupt blocks; stop before Spark.' }
```

Chạy từng job ở client mode. Kết quả được in ra cửa sổ `spark-submit`; ghi lại YARN
application ID từ output để kiểm tra state, allocation và logs theo phần Monitoring.

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 600s /opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_count.py'
docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 600s /opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_mean.py'
docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 600s /opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_median.py'
docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 600s /opt/spark/bin/spark-submit --master yarn --deploy-mode client /opt/pyspark/word_std_dev.py'
```

### Một Hive sales test

CSV nguồn là `/opt/data/online_retail.csv`; bảng external đọc từ
`/nhom14/input/hive_sales/online_retail.csv`. Trước DDL/query, kiểm tra đích và fsck:

```powershell
$csvPath = '/nhom14/input/hive_sales/online_retail.csv'
docker exec nghia-master su hadoopnghia -s /bin/bash -c '/opt/hadoop/bin/hdfs dfs -ls /nhom14/input/hive_sales'
if ($LASTEXITCODE -ne 0) { throw 'Không xác minh được Hive CSV directory.' }
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfs -test -e $csvPath"
$csvTest = $LASTEXITCODE
if ($csvTest -eq 0) {
    'CSV đã tồn tại; bỏ qua upload và không ghi đè.'
} elseif ($csvTest -eq 1) {
    docker exec nghia-master su hadoopnghia -s /bin/bash -c 'test -s /opt/data/online_retail.csv'
    if ($LASTEXITCODE -ne 0) { throw 'CSV nguồn không tồn tại hoặc rỗng.' }
    docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs dfs -put /opt/data/online_retail.csv $csvPath"
    if ($LASTEXITCODE -ne 0) { throw 'CSV upload thất bại; giữ nguyên dữ liệu hiện tại.' }
} else { throw 'Lỗi khi kiểm tra đích HDFS; không upload.' }

docker exec nghia-master su hadoopnghia -s /bin/bash -c '/opt/hadoop/bin/hdfs dfs -test -s /nhom14/input/hive_sales/online_retail.csv'
if ($LASTEXITCODE -ne 0) { throw 'Hive CSV không tồn tại hoặc rỗng; dừng trước fsck/DDL.' }
$csvFsck = docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 120s /opt/hadoop/bin/hdfs fsck /nhom14/input/hive_sales/online_retail.csv -files -blocks -locations' 2>&1
$csvFsckExit = $LASTEXITCODE
$csvFsck
$csvFsckText = $csvFsck -join "`n"
if ($csvFsckExit -ne 0 -or $csvFsckText -match '(?im)Status:\s*CORRUPT|MISSING BLOCKS:?[ \t]*[1-9][0-9]*|CORRUPT BLOCKS:?[ \t]*[1-9][0-9]*') { throw 'CSV fsck failed or found missing/corrupt blocks; stop before Hive DDL/query.' }
```

Chỉ tiếp tục nếu CSV tồn tại, `fsck` không báo missing/corrupt block và Hive helper đã xác nhận
JDBC. Sau đó chạy DDL, xác nhận đúng 8 cột, rồi thực hiện query có timeout và giới hạn kết quả:

`hive/01_create_warehouse.sql` định nghĩa đúng tám cột `invoice`, `stockcode`, `description`,
`quantity`, `invoicedate`, `price`, `customer_id`, `country` và dùng LOCATION
`/nhom14/input/hive_sales`. Script có `DROP TABLE IF EXISTS sales_warehouse` nhưng tạo
`online_retail` bằng `IF NOT EXISTS`; nó không thay thế schema của một bảng `online_retail`
đã tồn tại. Kiểm tra metadata trước; nếu bảng hiện có khác tám cột dự kiến, dừng và xử lý
metadata riêng biệt thay vì xóa bảng hay dữ liệu trong bước này.

```powershell
docker exec nghia-master su hadoopnghia -s /bin/bash -c 'timeout 120s /opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/default -f /opt/hive-scripts/01_create_warehouse.sql'
docker exec nghia-master su hadoopnghia -s /bin/bash -c "timeout 60s /opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -e 'DESCRIBE online_retail;'"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "timeout 120s /opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -e 'SELECT invoice, stockcode, description, quantity, invoicedate, price, customer_id, country FROM online_retail LIMIT 5; SELECT country, COUNT(*) AS sales_rows FROM online_retail GROUP BY country ORDER BY sales_rows DESC LIMIT 5;'"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/bigdata_n14_db -e 'SET hive.execution.engine;'"
docker exec nghia-master su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/yarn application -list -appStates ALL"
```

`DESCRIBE` must show the eight fields above. If the query submits work to YARN, find its
application ID in the command output/RM UI by application name and submission time, then use the
application/attempt/container commands in the Monitoring section to identify the NodeManager
where its containers ran and request their logs. If Hive executes locally in HiveServer2 instead,
the work ran in the Master process; `SET hive.execution.engine` helps distinguish the configured
engine. Neither execution mode nor node allocation has been runtime-verified here.
