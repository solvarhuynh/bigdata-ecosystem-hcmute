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
datanode_rows="$(printf '%s\n' "$report" | awk '
    /^Name:/ { endpoint = $2 }
    /^Hostname:/ && endpoint != "" { print endpoint "\t" $2; endpoint = "" }
')"
read -r unique_endpoints unique_hostnames < <(printf '%s\n' "$datanode_rows" | awk -F '\t' '
    NF == 2 { endpoints[$1] = 1; hostnames[$2] = 1 }
    END {
        for (value in endpoints) endpoint_count++
        for (value in hostnames) hostname_count++
        print endpoint_count + 0, hostname_count + 0
    }
')
bad_endpoint="$(printf '%s\n' "$datanode_rows" | awk -F '\t' '$1 ~ /^(127\.|localhost:|0\.0\.0\.0:|\[::1\])/ { print $1 }')"
bad_datanode_state="$(printf '%s\n' "$report" | awk '
    function check_node() {
        if (endpoint != "" && (capacity <= 0 || last_report == "Never")) {
            print hostname " capacity=" capacity " lastBlockReport=" last_report
        }
    }
    /^Name:/ {
        check_node()
        endpoint = $2
        hostname = "unknown"
        capacity = 0
        last_report = "missing"
    }
    /^Hostname:/ { hostname = $2 }
    /^Configured Capacity:/ { capacity = $3 + 0 }
    /^Last Block Report:/ {
        if ($0 ~ /: Never$/) last_report = "Never"
        else last_report = "received"
    }
    END { check_node() }
')"
if [ "$target" = "local" ]; then
    expected_worker_mappings="$(docker exec nghia-master /bin/bash -c 'printf "%s\t%s\n" "$WORKER1_HOSTNAME" "$WORKER1_IP"' 2>/dev/null || true)"
else
    expected_worker_mappings="$(docker exec nghia-master /bin/bash -c 'printf "%s\t%s\n" "$WORKER1_HOSTNAME" "$WORKER1_IP" "$WORKER2_HOSTNAME" "$WORKER2_IP" "$WORKER3_HOSTNAME" "$WORKER3_IP" "$WORKER4_HOSTNAME" "$WORKER4_IP"' 2>/dev/null || true)"
fi
configured_hostname_count="$(printf '%s\n' "$expected_worker_mappings" | awk -F '\t' 'NF == 2 && $1 != "" && $2 != "" { count++ } END { print count+0 }')"
reported_worker_hostnames="$(printf '%s\n' "$datanode_rows" | awk -F '\t' 'NF == 2 { print $2 }' | sort -u)"
missing_worker_hostnames=""
bad_worker_ip_mappings=""
while IFS=$'\t' read -r expected_hostname expected_ip; do
    [ -n "$expected_hostname" ] || continue
    if ! printf '%s\n' "$reported_worker_hostnames" | grep -Fxq "$expected_hostname"; then
        missing_worker_hostnames="${missing_worker_hostnames} ${expected_hostname}"
        continue
    fi
    actual_endpoint="$(printf '%s\n' "$datanode_rows" | awk -F '\t' -v hostname="$expected_hostname" '$2 == hostname { print $1; exit }')"
    actual_ip="${actual_endpoint%:*}"
    if [ -n "$actual_endpoint" ] && [ "$actual_ip" != "$expected_ip" ]; then
        bad_worker_ip_mappings="${bad_worker_ip_mappings} ${expected_hostname}=${actual_ip} (expected ${expected_ip})"
    fi
done <<< "$expected_worker_mappings"

echo "Expected workers: ${expected}"
echo "Live DataNodes: ${live_datanodes}"
echo "Unique DataNode endpoints: ${unique_endpoints}"
echo "Unique DataNode hostnames: ${unique_hostnames}"
echo "Configured worker hostnames: ${configured_hostname_count}"
echo "DataNodes with capacity/report issues: $(printf '%s\n' "$bad_datanode_state" | awk 'NF { count++ } END { print count+0 }')"
echo "Running NodeManagers: ${running_nodemanagers}"

if [ "$live_datanodes" -ne "$expected" ] ||
   [ "$running_nodemanagers" -ne "$expected" ] ||
   [ "$unique_endpoints" -ne "$expected" ] ||
   [ "$unique_hostnames" -ne "$expected" ] ||
   [ "$configured_hostname_count" -ne "$expected" ] ||
   [ -n "$bad_endpoint" ] ||
   [ -n "$bad_datanode_state" ] ||
   [ -n "$missing_worker_hostnames" ] ||
   [ -n "$bad_worker_ip_mappings" ]; then
    echo "FAIL: số Worker hoặc endpoint/hostname DataNode không đạt yêu cầu."
    [ -z "$bad_endpoint" ] || echo "Loopback/wildcard DataNode endpoint:${bad_endpoint}"
    [ -z "$bad_datanode_state" ] || { echo "DataNode capacity/block-report issue:"; printf '%s\n' "$bad_datanode_state"; }
    [ -z "$missing_worker_hostnames" ] || echo "Thiếu hostname đã cấu hình:${missing_worker_hostnames}"
    [ -z "$bad_worker_ip_mappings" ] || echo "DataNode endpoint không khớp IP cấu hình:${bad_worker_ip_mappings}"
    echo "--- DataNode endpoint / hostname ---"
    printf '%s\n' "$datanode_rows"
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
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -test -s /test_bigdata/input/description.txt'; then
    echo "FAIL: HDFS input /test_bigdata/input/description.txt không tồn tại hoặc rỗng." >&2
    echo "Kiểm tra /opt/data/description.txt trên Master; nếu HDFS path chưa tồn tại, nạp file bằng hdfs dfs -put (không dùng -f)." >&2
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
