#!/bin/bash
set -e
set -o pipefail

target="${1:-}"
timeout_seconds=120
case "$target" in
    local) expected=1 ;;
    full) expected=4 ;;
    *)
        echo "Dùng: bash scripts/check_cluster.sh local|full" >&2
        exit 2
        ;;
esac

if [ "$(docker inspect -f '{{.State.Status}}' nghia-master 2>/dev/null)" != "running" ]; then
    echo "ERROR: nghia-master không ở trạng thái running." >&2
    docker ps -a --filter name=nghia-master
    docker logs nghia-master --tail 120
    exit 1
fi

hadoop_exec() {
    docker exec nghia-master su hadoopnghia -s /bin/bash -c "$1"
}

wait_for_safemode_off() {
    local safe_mode_wait
    if safe_mode_wait="$(hadoop_exec "timeout ${timeout_seconds}s /opt/hadoop/bin/hdfs dfsadmin -safemode wait" 2>&1)"; then
        echo "${safe_mode_wait}"
        echo "SafeMode: OFF"
        return 0
    fi
    echo "FAIL: hdfs dfsadmin -safemode wait thất bại hoặc timeout sau ${timeout_seconds}s."
    echo "--- SafeMode ---"
    hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -safemode get' 2>&1 || true
    echo "--- HDFS report ---"
    hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -report' 2>&1 || true
    echo "--- YARN node list ---"
    hadoop_exec '/opt/hadoop/bin/yarn node -list -all' 2>&1 || true
    echo "--- Master log ---"
    docker logs nghia-master --tail 120 2>&1 || true
    return 1
}

if ! report="$(hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -report' 2>&1)"; then
    echo "FAIL: không lấy được HDFS report." >&2
    printf '%s\n' "$report"
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
live_datanodes="$(printf '%s\n' "$report" | awk -F'[()]' '/Live datanodes/ { print $2; exit }')"
live_datanodes="${live_datanodes:-0}"

if ! yarn_nodes="$(hadoop_exec '/opt/hadoop/bin/yarn node -list -all' 2>&1)"; then
    echo "FAIL: không lấy được YARN node list." >&2
    printf '%s\n' "$yarn_nodes"
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
running_nodemanagers="$(printf '%s\n' "$yarn_nodes" | awk '/RUNNING/ { count++ } END { print count+0 }')"

echo "Expected workers: ${expected}"
echo "Live DataNodes: ${live_datanodes}"
echo "Running NodeManagers: ${running_nodemanagers}"

if [ "$live_datanodes" -ne "$expected" ] || [ "$running_nodemanagers" -ne "$expected" ]; then
    echo "FAIL: số Worker chưa đạt yêu cầu."
    echo "--- HDFS report ---"
    printf '%s\n' "$report"
    echo "--- YARN node list ---"
    printf '%s\n' "$yarn_nodes"
    echo "--- Master log ---"
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi

if ! wait_for_safemode_off; then
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -mkdir -p /tmp /user/hive/warehouse /test_bigdata/input /test_bigdata/hive_sales'; then
    echo "FAIL: không tạo được thư mục HDFS; dừng trước bước chmod." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod -R 777 /tmp /user/hive/warehouse /test_bigdata'; then
    echo "FAIL: không cập nhật được quyền thư mục HDFS." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
echo "PASS: ${expected} DataNode và ${expected} NodeManager đang hoạt động."
