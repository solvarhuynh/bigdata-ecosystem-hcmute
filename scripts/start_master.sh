#!/bin/bash
set -euo pipefail

compose_file="docker/docker-compose.master.yml"
container="nghia-master"
service="master"
timeout_seconds=900

normalize_started_at() {
    local value="${1:-}"
    if [ -n "$value" ] && [[ "$value" != 0001-* ]]; then
        printf '%s\n' "$value"
    else
        date -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

if [ "${START_MASTER_TEST_MODE:-}" = "timestamp" ]; then
    provided="2026-10-24T12:34:56Z"
    [ "$(normalize_started_at "$provided")" = "$provided" ] || { echo "FAIL: existing timestamp changed." >&2; exit 1; }
    for missing in "" "0001-01-01T00:00:00Z"; do
        fallback="$(normalize_started_at "$missing")"
        [[ "$fallback" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
            echo "FAIL: fallback timestamp has an invalid format." >&2
            exit 1
        }
    done
    echo "PASS: start_master preserves valid timestamps and generates UTC fallback timestamps."
    exit 0
fi

check_master_services() {
    local started_at="$1"
    local phase readiness_marker
    phase="$(docker exec "$container" printenv MASTER_START_PHASE 2>/dev/null || true)"
    phase="${phase:-core}"
    case "$phase" in
        core) readiness_marker='Master core services đã sẵn sàng:' ;;
        full) readiness_marker='Master full services đã sẵn sàng:' ;;
        *) echo "ERROR: MASTER_START_PHASE không hợp lệ: ${phase}." >&2; return 1 ;;
    esac

    if ! docker exec "$container" bash -lc '
        set -e
        phase="${MASTER_START_PHASE:-core}"
        ports="9000 8032 9870 8088"
        if [ "$phase" = full ]; then ports="$ports 9083 10000"; fi
        for port in $ports; do
            timeout 1 bash -c ": </dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
        done
        jps_output="$(su hadoopnghia -s /bin/bash -c "jps")"
        printf "%s\n" "$jps_output" | grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+NameNode([[:space:]]|$)"
        printf "%s\n" "$jps_output" | grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+ResourceManager([[:space:]]|$)"
    '; then
        return 1
    fi

    docker logs "$container" --since "$started_at" 2>&1 | grep -F "$readiness_marker" >/dev/null
}

show_failure() {
    local started_at="$1"
    echo "--- Container state ---" >&2
    docker inspect -f '{{.State.Status}} start={{.State.StartedAt}} finish={{.State.FinishedAt}}' "$container" 2>&1 || true
    docker ps -a --filter "name=^/${container}$" >&2
    echo "--- Log phiên hiện tại ---" >&2
    docker logs "$container" --since "$started_at" --tail 120 2>&1 || true
    echo "--- Log mới nhất ---" >&2
    docker logs "$container" --tail 120 2>&1 || true
}

report_active_phase() {
    local phase="$1"
    echo "Phase hiệu lực trong container: MASTER_START_PHASE=${phase}; container đang chạy sẽ không được restart tự động vì thay đổi .env."
    echo "Nếu cần đổi phase, chỉ sau khi được phê duyệt và xác nhận đúng volume, mới chạy:"
    echo "docker compose --env-file .env -f ${compose_file} up -d --force-recreate ${service}"
    echo "Recreate có thể gây downtime nhưng không xóa named volume."
}

echo "=== [BigData-N14] Khởi động Master (${container}) ==="

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
        run_started_at="$(normalize_started_at "$run_started_at")"
        active_phase="$(docker exec "$container" printenv MASTER_START_PHASE 2>/dev/null || true)"
        active_phase="${active_phase:-core}"
        echo "${container} đang running; không restart container."
        report_active_phase "$active_phase"
        if check_master_services "$run_started_at"; then
            echo "PASS: Master phase=${active_phase}; dịch vụ bắt buộc sẵn sàng; giữ nguyên container và volume."
            if [ "$active_phase" = core ]; then
                echo "Sau khi khởi động worker1 và worker3, chạy: bash scripts/check_cluster.sh pilot"
            else
                echo "Hive phase=full đã được xác nhận; trạng thái toàn cụm vẫn cần check_cluster.sh."
            fi
            exit 0
        fi
        echo "ERROR: ${container} đang running nhưng dịch vụ bắt buộc chưa sẵn sàng; không restart." >&2
        show_failure "$run_started_at"
        exit 1
        ;;
    restarting|paused)
        echo "ERROR: ${container} đang ở trạng thái ${state_before}; không tiếp tục." >&2
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
        echo "ERROR: trạng thái container không hỗ trợ: ${state_before}." >&2
        docker ps -a --filter "name=^/${container}$"
        exit 1
        ;;
esac

run_started_at="$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null || true)"
run_started_at="$(normalize_started_at "$run_started_at")"

echo "=== Đang chờ readiness marker của lần khởi động hiện tại (tối đa ${timeout_seconds}s) ==="
last_state=""
for attempt in $(seq 1 "$timeout_seconds"); do
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    [ -n "$state" ] || state="missing"
    if [ "$state" != "$last_state" ]; then
        echo "Container state: ${state}"
        last_state="$state"
    fi

    case "$state" in
        exited|dead|restarting|paused|missing)
            echo "ERROR: ${container} vào trạng thái ${state} trong khi chờ." >&2
            show_failure "$run_started_at"
            exit 1
            ;;
        created)
            ;;
        running)
            if check_master_services "$run_started_at"; then
                phase="$(docker exec "$container" printenv MASTER_START_PHASE 2>/dev/null || echo core)"
                echo "PASS: Master phase=${phase}; container, NameNode, ResourceManager và readiness log hiện tại đã được xác minh."
                if [ "$phase" = core ]; then
                    echo "Sau khi khởi động worker1 và worker3, chạy: bash scripts/check_cluster.sh pilot"
                else
                    echo "Hive JDBC đã được kiểm tra bởi startup helper; DataNode/NodeManager cần check_cluster.sh riêng."
                fi
                exit 0
            fi
            ;;
        *)
            echo "ERROR: trạng thái container không hỗ trợ: ${state}." >&2
            show_failure "$run_started_at"
            exit 1
            ;;
    esac
    sleep 1
done

echo "ERROR: ${container} không xác nhận dịch vụ Master bắt buộc trong ${timeout_seconds}s." >&2
show_failure "$run_started_at"
exit 1
