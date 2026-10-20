#!/bin/bash
set -e
set -o pipefail

compose_file="docker/docker-compose.master.yml"
container="nghia-master"
service="master"
timeout_seconds=360

check_master_services() {
    local started_at="$1"
    if ! docker exec "$container" bash -lc '
        set -e
        for port in 9000 8032 9083; do
            timeout 1 bash -c ": </dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
        done
        jps_output="$(su hadoopnghia -s /bin/bash -c "jps")"
        printf "%s\n" "$jps_output" | grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+NameNode([[:space:]]|$)"
        printf "%s\n" "$jps_output" | grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+ResourceManager([[:space:]]|$)"
    '; then
        return 1
    fi
    docker logs "$container" --since "$started_at" 2>&1 | grep -F 'Master core services đã sẵn sàng:' >/dev/null
}

show_failure_logs() {
    echo "--- Container state ---"
    docker inspect -f '{{.State.Status}} start={{.State.StartedAt}} finish={{.State.FinishedAt}}' "$container" 2>&1 || true
    docker ps -a --filter "name=^/${container}$"
    echo "--- Log phiên hiện tại ---"
    docker logs "$container" --since "$1" --tail 120 2>&1 || true
    echo "--- Log mới nhất ---"
    docker logs "$container" --tail 120 2>&1 || true
}

echo "=== [BigData-N14] Khởi động Master Cluster (${container}) ==="

if [ ! -f .env ]; then
    echo "Không tìm thấy file .env, đang copy từ .env.example..."
    cp .env.example .env
    echo "Đã tạo .env. Hãy điền IP và hostname thật rồi chạy lại script."
    exit 1
fi

state_before="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
[ -n "$state_before" ] || state_before="missing"

case "$state_before" in
    running)
        run_started_at="$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null || true)"
        if [ -z "$run_started_at" ] || [[ "$run_started_at" == 0001-* ]]; then
            run_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi
        echo "${container} đang running; không restart container."
        if check_master_services "$run_started_at"; then
            echo "PASS: Master core services đang sẵn sàng; giữ nguyên container và volume hiện tại."
            echo "HiveServer2, DataNode và NodeManager sẽ được kiểm tra sau khi Worker khởi động: bash scripts/check_cluster.sh full"
            exit 0
        fi
        echo "ERROR: ${container} đang running nhưng Master services chưa sẵn sàng." >&2
        show_failure_logs "$run_started_at"
        exit 1
        ;;
    restarting)
        echo "ERROR: ${container} đang ở trạng thái restarting; không tiếp tục." >&2
        docker ps -a --filter "name=^/${container}$"
        docker logs "$container" --tail 120 2>&1 || true
        exit 1
        ;;
    created|exited|dead|missing)
        if ! docker compose -f "$compose_file" --env-file .env up -d "$service"; then
            echo "ERROR: không khởi động được service ${service}." >&2
            docker compose -f "$compose_file" --env-file .env ps -a
            docker logs "$container" --tail 120 2>&1 || true
            exit 1
        fi
        ;;
    *)
        echo "ERROR: trạng thái trước khởi động không hỗ trợ: ${state_before}" >&2
        docker ps -a --filter "name=^/${container}$"
        exit 1
        ;;
esac

run_started_at="$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null || true)"
if [ -z "$run_started_at" ] || [[ "$run_started_at" == 0001-* ]]; then
    run_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

echo "=== Đang chờ phiên khởi động hiện tại xác nhận dịch vụ ==="
last_state=""
for attempt in $(seq 1 "$timeout_seconds"); do
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    [ -n "$state" ] || state="missing"
    if [ "$state" != "$last_state" ]; then
        echo "Container state: ${state:-missing}"
        last_state="$state"
    fi

    case "$state" in
        exited|dead)
            echo "ERROR: ${container} đã dừng với mã $(docker inspect -f '{{.State.ExitCode}}' "$container" 2>/dev/null || echo unknown)." >&2
            echo "--- Container state ---"
            docker inspect -f '{{.State.Status}} start={{.State.StartedAt}} finish={{.State.FinishedAt}}' "$container" 2>&1 || true
            echo "--- Log phiên khởi động hiện tại ---"
            docker logs "$container" --since "$run_started_at" --tail 120 2>&1 || true
            echo "--- Log mới nhất ---"
            docker logs "$container" --tail 120 2>&1 || true
            exit 1
            ;;
        restarting)
            echo "ERROR: ${container} đang restart loop." >&2
            docker ps -a --filter "name=^/${container}$"
            docker logs "$container" --since "$run_started_at" --tail 120 2>&1 || true
            docker logs "$container" --tail 120 2>&1 || true
            exit 1
            ;;
        created)
            ;;
        missing)
            echo "ERROR: container ${container} không tồn tại trong khi chờ khởi động." >&2
            docker compose -f "$compose_file" --env-file .env ps -a
            exit 1
            ;;
        running)
            if check_master_services "$run_started_at"; then
                echo "=== Master core services đã sẵn sàng trong phiên khởi động hiện tại ==="
                echo "Đã kiểm tra container running, NameNode, ResourceManager, Metastore và log hiện tại."
                echo "HiveServer2, DataNode và NodeManager sẽ được kiểm tra sau khi Worker khởi động: bash scripts/check_cluster.sh full"
                exit 0
            fi
            ;;
        paused)
            echo "ERROR: ${container} đang paused." >&2
            docker ps -a --filter "name=^/${container}$"
            docker logs "$container" --tail 120 2>&1 || true
            exit 1
            ;;
    esac
    sleep 1
done

echo "ERROR: ${container} không xác nhận sẵn sàng trong ${timeout_seconds}s." >&2
show_failure_logs "$run_started_at"
exit 1
