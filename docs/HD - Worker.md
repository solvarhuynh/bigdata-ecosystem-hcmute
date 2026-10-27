# BigData-N14 --- Hướng dẫn nhanh cho Worker

## 1. Khởi động Worker

``` powershell4
docker compose --env-file .env -f docker/docker-compose.worker.yml up -d
```
### Kiểm tra tiến trình:

```powershell
docker exec khang-worker bash -lc "jps"
```

## 2. NẾU LỖI - Xem log khi khởi động

Thay `TEN_CONTAINER` bằng tên container của mình:

``` powershell
docker ps
docker logs --tail 100 TEN_CONTAINER
```

## 3. Kiểm tra HDFS và YARN

### Kiểm tra HDFS:

```powershell
docker exec -u hadoopnghia khang-worker hdfs dfsadmin -report
docker exec -u hadoopnghia khang-worker hdfs dfsadmin -safemode get
```

### Kiểm tra các Worker đăng ký với YARN:

```powershell
docker exec -u hadoopnghia khang-worker yarn node -list -all
```

## Chỉ khởi động thủ công nếu xác nhận daemon đang thiếu

Trên chính `máy Worker` bị thiếu `DataNode`. Ví dụ máy Khang:

```powershell
docker exec -u hadoopnghia khang-worker hdfs --daemon start datanode
```

Trên chính máy Worker bị thiếu `NodeManager`:

```powershell
docker exec -u hadoopnghia khang-worker yarn --daemon start nodemanager
```