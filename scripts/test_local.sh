#!/bin/bash
set -e
set -o pipefail

compose_file="docker/docker-compose.local.yml"
timeout_seconds=360

print_node_failure() {
    local label="$1"
    local service="$2"
    local container_id="$3"
    echo "ERROR: ${label} (${service}) chưa ở trạng thái running hoặc không tìm thấy container." >&2
    if [ -n "$container_id" ]; then
        docker inspect -f '{{.Name}} state={{.State.Status}} start={{.State.StartedAt}} finish={{.State.FinishedAt}}' "$container_id" 2>&1 || true
        docker logs "$container_id" --tail 120 2>&1 || true
    else
        echo "Không tìm thấy container ID của ${label}; không có log container để in."
        docker compose -f "$compose_file" ps -a
    fi
}

master_services_ready() {
    docker exec "$1" bash -lc '
        set -e
        for port in 9000 8032 9083 10000 10002; do
            timeout 1 bash -c ": </dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
        done
        jps_output="$(su hadoopnghia -s /bin/bash -c "jps")"
        printf "%s\n" "$jps_output" |
            grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+NameNode([[:space:]]|$)"

        printf "%s\n" "$jps_output" |
            grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+ResourceManager([[:space:]]|$)"
}

echo "=== [BigData-N14] Khởi động cụm local 1 Master + 1 Worker ==="
if ! docker compose -f "$compose_file" up -d; then
    echo "ERROR: không khởi động được Compose local." >&2
    docker compose -f "$compose_file" ps -a
    exit 1
fi

for attempt in $(seq 1 "$timeout_seconds"); do
    master_id="$(docker compose -f "$compose_file" ps -aq nghia-master | head -n 1)"
    worker_id="$(docker compose -f "$compose_file" ps -aq worker1 | head -n 1)"

    if [ -z "$master_id" ]; then
        print_node_failure "Master" "nghia-master" ""
        docker compose -f "$compose_file" ps -a
        exit 1
    fi
    if [ -z "$worker_id" ]; then
        print_node_failure "Worker logic worker1" "worker1" ""
        docker compose -f "$compose_file" ps -a
        exit 1
    fi

    master_state="$(docker inspect -f '{{.State.Status}}' "$master_id" 2>/dev/null || true)"
    worker_state="$(docker inspect -f '{{.State.Status}}' "$worker_id" 2>/dev/null || true)"

    case "$master_state" in
        exited|dead|restarting)
            print_node_failure "Master" "nghia-master" "$master_id"
            exit 1
            ;;
    esac
    case "$worker_state" in
        exited|dead|restarting)
            print_node_failure "Worker logic worker1" "worker1" "$worker_id"
            exit 1
            ;;
    esac

    if [ "$master_state" = "running" ] && [ "$worker_state" = "running" ]; then
        if master_services_ready "$master_id"; then
            echo "PASS: Master và Worker container đang running; các dịch vụ Master bắt buộc đang lắng nghe."
            echo "Đây chưa phải xác nhận đủ DataNode/NodeManager hoặc toàn bộ cluster."
            echo "Bước kiểm tra DataNode/NodeManager: bash scripts/check_cluster.sh local"
            docker compose -f "$compose_file" ps
            exit 0
        fi
    fi
    sleep 1
done

echo "ERROR: local cluster không đạt trạng thái running và Master readiness trong ${timeout_seconds}s." >&2
docker compose -f "$compose_file" ps -a
print_node_failure "Master" "nghia-master" "$master_id"
print_node_failure "Worker logic worker1" "worker1" "$worker_id"
exit 1
