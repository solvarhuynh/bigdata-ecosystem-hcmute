#!/bin/bash
set -e
set -o pipefail

target="${1:-}"
safemode_timeout_seconds=120
hive_timeout_seconds=180
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
    if safe_mode_wait="$(hadoop_exec "timeout ${safemode_timeout_seconds}s /opt/hadoop/bin/hdfs dfsadmin -safemode wait" 2>&1)"; then
        echo "${safe_mode_wait}"
        echo "SafeMode: OFF"
        return 0
    fi
    echo "FAIL: hdfs dfsadmin -safemode wait thất bại hoặc timeout sau ${safemode_timeout_seconds}s."
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

wait_for_hiveserver2() {
    local attempt
    local ready=false
    for attempt in $(seq 1 "$hive_timeout_seconds"); do
        if docker exec nghia-master bash -lc 'timeout 1 bash -c ": </dev/tcp/127.0.0.1/10000"' >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 1
    done

    if [ "$ready" != true ]; then
        echo "FAIL: HiveServer2 Thrift chưa lắng nghe sau ${hive_timeout_seconds}s."
        echo "--- SafeMode ---"
        hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -safemode get' 2>&1 || true
        echo "--- HDFS report ---"
        hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -report' 2>&1 || true
        echo "--- YARN node list ---"
        hadoop_exec '/opt/hadoop/bin/yarn node -list -all' 2>&1 || true
        echo "--- Master log ---"
        docker logs nghia-master --tail 120 2>&1 || true
        echo "--- HiveServer2 log ---"
        docker exec nghia-master tail -n 100 /opt/hive/logs/hiveserver2.log 2>&1 || true
        return 1
    fi

    echo "HiveServer2 Thrift đang lắng nghe; kiểm tra JDBC bằng SHOW DATABASES..."
    local jdbc_output
    if ! jdbc_output="$(docker exec nghia-master su hadoopnghia -s /bin/bash -c "timeout 60s /opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/default -e 'SHOW DATABASES;'" 2>&1)"; then
        echo "FAIL: HiveServer2 không hoàn tất truy vấn JDBC SHOW DATABASES."
        printf '%s\n' "$jdbc_output"
        echo "--- HiveServer2 log ---"
        docker exec nghia-master tail -n 100 /opt/hive/logs/hiveserver2.log 2>&1 || true
        return 1
    fi
    printf '%s\n' "$jdbc_output"
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
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -mkdir -p /tmp /tmp/hive /user/hive/warehouse /test_bigdata/input /test_bigdata/hive_sales'; then
    echo "FAIL: không tạo được thư mục HDFS; dừng trước bước chmod." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod 1777 /tmp'; then
    echo "FAIL: không cập nhật được quyền thư mục HDFS /tmp." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod 777 /tmp/hive /user/hive/warehouse /test_bigdata /test_bigdata/input /test_bigdata/hive_sales'; then
    echo "FAIL: không cập nhật được quyền các thư mục HDFS của Hive/bài thực hành." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! wait_for_hiveserver2; then
    exit 1
fi
echo "PASS: ${expected} DataNode, ${expected} NodeManager và HiveServer2 JDBC đang hoạt động."
