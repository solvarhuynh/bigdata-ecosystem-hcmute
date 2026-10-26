# BigData-N14 --- Hướng dẫn nhanh cho Worker

## 1. Khởi động Worker

``` powershell4
docker compose --env-file .env -f docker/docker-compose.worker.yml up -d
```

## 2. NẾU LỖI - Xem log khi khởi động

Thay `TEN_CONTAINER` bằng tên container của mình:

``` powershell
docker ps
docker logs --tail 100 TEN_CONTAINER
```

