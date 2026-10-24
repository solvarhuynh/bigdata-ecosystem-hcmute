#!/bin/bash
set -euo pipefail

target="${1:-}"
safemode_timeout_seconds=120
fsck_timeout_seconds=180
hive_timeout_seconds=180
fsck_diagnostic_timeout_seconds=60

load_expected_slots() {
    case "$1" in
        local) expected_slots=(1); hive_required=true ;;
        pilot) expected_slots=(1 3); hive_required=false ;;
        full) expected_slots=(1 2 3 4); hive_required=true ;;
        *) return 1 ;;
    esac
    expected="${#expected_slots[@]}"
}

running_yarn_aliases() {
    awk '$2 == "RUNNING" { node = $1; sub(/:[0-9]+$/, "", node); print node }' <<< "$1" | sort -u
}

yarn_alias_is_running() {
    printf '%s\n' "$1" | grep -Fxq "$2"
}

hostname_maps_to_expected_ip() {
    [ -n "$1" ] && [ "$1" = "$2" ]
}

fsck_has_damage() {
    grep -Eiq 'Status:[[:space:]]*CORRUPT|MISSING BLOCKS:?[[:space:]]*[1-9][0-9]*|CORRUPT BLOCKS:?[[:space:]]*[1-9][0-9]*' <<< "$1"
}

parse_live_datanodes() {
    awk '
        function reset_record() {
            endpoint = "-"
            hostname = "-"
            last_contact = "-"
            capacity = "0"
            last_report = "-"
        }
        function emit_record() {
            if (in_live && endpoint != "-") {
                print endpoint "\t" hostname "\t" last_contact "\t" capacity "\t" last_report
            }
        }
        /^Live datanodes/ { if (in_live) emit_record(); in_live = 1; reset_record(); next }
        /^(Dead|Decommissioning|Decommissioned|In maintenance) datanodes/ { emit_record(); in_live = 0; next }
        in_live && /^Name:/ { emit_record(); reset_record(); endpoint = $2; next }
        in_live && /^Hostname:/ { hostname = $2; next }
        in_live && /^Configured Capacity:/ {
            capacity = $3
            gsub(/,/, "", capacity)
            if (capacity !~ /^[0-9]+([.][0-9]+)?$/) capacity = "0"
            next
        }
        in_live && /^Last contact:/ {
            last_contact = $0
            sub(/^Last contact:[[:space:]]*/, "", last_contact)
            sub(/[[:space:]]+$/, "", last_contact)
            next
        }
        in_live && /^Last Block Report:/ {
            last_report = $0
            sub(/^Last Block Report:[[:space:]]*/, "", last_report)
            sub(/[[:space:]]+$/, "", last_report)
            next
        }
        END { emit_record() }
    ' <<< "$1"
}

datanode_state_issues() {
    awk -F '\t' '
        NF != 5 || $1 == "" || $1 == "-" || $2 == "" || $2 == "-" ||
        $3 == "" || $3 == "-" || tolower($3) == "never" ||
        $4 !~ /^[0-9]+([.][0-9]+)?$/ || $4 + 0 <= 0 ||
        $5 == "" || $5 == "-" || tolower($5) == "never" {
            print $2 " endpoint=" $1 " capacity=" $4 " lastContact=" $3 " lastBlockReport=" $5
        }
    ' <<< "$1"
}

if [ "$target" = "--self-test" ]; then
    expected_slots=()
    load_expected_slots local && [ "${expected_slots[*]}:${expected}" = "1:1" ] || exit 1
    load_expected_slots pilot && [ "${expected_slots[*]}:${expected}" = "1 3:2" ] || exit 1
    load_expected_slots full && [ "${expected_slots[*]}:${expected}" = "1 2 3 4:4" ] || exit 1
    for damaged_fsck in 'Status: CORRUPT' 'MISSING BLOCKS: 1' 'MISSING BLOCKS 2' 'CORRUPT BLOCKS: 3'; do
        fsck_has_damage "$damaged_fsck" || { echo "FAIL: fsck damage was not detected: ${damaged_fsck}" >&2; exit 1; }
    done
    if fsck_has_damage $'Status: HEALTHY\nMISSING BLOCKS: 0\nCORRUPT BLOCKS: 0'; then
        echo "FAIL: healthy fsck fixture was marked damaged." >&2
        exit 1
    fi
    hostname_maps_to_expected_ip 192.0.2.11 192.0.2.11 || {
        echo "FAIL: matching hostname resolution was rejected." >&2
        exit 1
    }
    if hostname_maps_to_expected_ip 192.0.2.12 192.0.2.11 || hostname_maps_to_expected_ip "" 192.0.2.11; then
        echo "FAIL: mismatched or unresolved hostname resolution was accepted." >&2
        exit 1
    fi

    datanode_fixture="$(cat <<'EOF'
Live datanodes (2):
Name: 100.64.0.11:9866 (worker1/100.64.0.11)
Hostname: An-worker
Configured Capacity: 1,073,741,824 (1 GB)
Last contact: Wed Oct 21 10:00:00 UTC 2026
Last Block Report: Wed Oct 21 09:59:00 UTC 2026
Name: 100.64.0.13:9866 (worker3/100.64.0.13)
Hostname: Binh-slave
Configured Capacity: 2,147,483,648 (2 GB)
Last contact: Wed Oct 21 10:00:01 UTC 2026
Last Block Report: Wed Oct 21 09:59:01 UTC 2026
EOF
)"
    datanode_rows="$(parse_live_datanodes "$datanode_fixture")"
    worker1_record="$(awk -F '\t' '$2 == "An-worker" { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }' <<< "$datanode_rows")"
    worker3_record="$(awk -F '\t' '$2 == "Binh-slave" { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }' <<< "$datanode_rows")"
    [[ "$worker1_record" == $'100.64.0.11:9866\tAn-worker\tWed Oct 21 10:00:00 UTC 2026\t1073741824\tWed Oct 21 09:59:00 UTC 2026' ]] || {
        echo "FAIL: endpoint, hostname, Last contact, capacity or block report crossed DataNode records." >&2
        exit 1
    }
    [[ "$worker3_record" == $'100.64.0.13:9866\tBinh-slave\tWed Oct 21 10:00:01 UTC 2026\t2147483648\tWed Oct 21 09:59:01 UTC 2026' ]] || {
        echo "FAIL: worker3 fixture fields were not kept in one DataNode record." >&2
        exit 1
    }
    [ -z "$(datanode_state_issues "$datanode_rows")" ] || {
        echo "FAIL: complete DataNode fixture was reported unhealthy." >&2
        exit 1
    }
    for invalid_record in \
        $'-\tAn-worker\tWed Oct 21 10:00:00 UTC 2026\t1073741824\tWed Oct 21 09:59:00 UTC 2026' \
        $'100.64.0.11:9866\t-\tWed Oct 21 10:00:00 UTC 2026\t1073741824\tWed Oct 21 09:59:00 UTC 2026' \
        $'100.64.0.11:9866\tAn-worker\t-\t1073741824\tWed Oct 21 09:59:00 UTC 2026' \
        $'100.64.0.11:9866\tAn-worker\tNever\t1073741824\tWed Oct 21 09:59:00 UTC 2026' \
        $'100.64.0.11:9866\tAn-worker\tWed Oct 21 10:00:00 UTC 2026\t0\tWed Oct 21 09:59:00 UTC 2026' \
        $'100.64.0.11:9866\tAn-worker\tWed Oct 21 10:00:00 UTC 2026\t1073741824\tNever' \
        $'100.64.0.11:9866\tAn-worker\tWed Oct 21 10:00:00 UTC 2026\t1073741824\t'; do
        [ -n "$(datanode_state_issues "$invalid_record")" ] || {
            echo "FAIL: incomplete or invalid DataNode record was accepted: ${invalid_record//$'\t'/|}" >&2
            exit 1
        }
    done

    yarn_fixture="$(cat <<'EOF'
Node-Id Node-State Node-Http-Address Number-of-Running-Containers
worker1:8041 RUNNING worker1:8042 0
worker3:8041 RUNNING worker3:8042 1
khang-worker:8041 LOST khang-worker:8042 0
hongkhoa-worker:8041 LOST hongkhoa-worker:8042 0
EOF
)"
    yarn_aliases="$(running_yarn_aliases "$yarn_fixture")"
    [[ "$yarn_aliases" == $'worker1\nworker3' ]] || {
        echo "FAIL: YARN parser returned an unexpected RUNNING alias set: ${yarn_aliases}" >&2
        exit 1
    }
    yarn_alias_is_running "$yarn_aliases" worker1 || exit 1
    yarn_alias_is_running "$yarn_aliases" worker3 || exit 1
    if yarn_alias_is_running "$yarn_aliases" khang-worker || yarn_alias_is_running "$yarn_aliases" hongkhoa-worker; then
        echo "FAIL: YARN test confused actual hostname with logical alias." >&2
        exit 1
    fi
    echo "PASS: local=1, pilot=worker1+worker3, full=4; DataNode fields stay grouped, fsck corruption markers are detected, and YARN checks use logical aliases."
    exit 0
fi

if ! load_expected_slots "$target"; then
    echo "Dùng: bash scripts/check_cluster.sh local|pilot|full (hoặc --self-test)" >&2
    exit 2
fi

if [ "$(docker inspect -f '{{.State.Status}}' nghia-master 2>/dev/null || true)" != "running" ]; then
    echo "ERROR: nghia-master không ở trạng thái running." >&2
    docker ps -a --filter name=nghia-master
    docker logs nghia-master --tail 120
    exit 1
fi

hadoop_exec() {
    docker exec nghia-master su hadoopnghia -s /bin/bash -c "$1"
}

run_fsck_diagnostic() {
    echo "--- Read-only HDFS fsck diagnostic (tối đa ${fsck_diagnostic_timeout_seconds}s) ---" >&2
    hadoop_exec "timeout ${fsck_diagnostic_timeout_seconds}s /opt/hadoop/bin/hdfs fsck / -files -blocks -locations" 2>&1 || true
}

wait_for_safemode_off() {
    local safe_mode_wait
    if safe_mode_wait="$(hadoop_exec "timeout ${safemode_timeout_seconds}s /opt/hadoop/bin/hdfs dfsadmin -safemode wait" 2>&1)"; then
        printf '%s\n' "$safe_mode_wait"
        echo "SafeMode: OFF"
        return 0
    fi
    echo "FAIL: SafeMode chưa tắt hoặc lệnh chờ timeout sau ${safemode_timeout_seconds}s." >&2
    echo "--- SafeMode ---" >&2
    hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -safemode get' 2>&1 || true
    echo "--- HDFS report ---" >&2
    hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -report' 2>&1 || true
    echo "--- YARN node list ---" >&2
    hadoop_exec '/opt/hadoop/bin/yarn node -list -all' 2>&1 || true
    echo "--- Master log ---" >&2
    docker logs nghia-master --tail 120 2>&1 || true
    run_fsck_diagnostic
    return 1
}

wait_for_hiveserver2() {
    local attempt jdbc_output
    for attempt in $(seq 1 "$hive_timeout_seconds"); do
        if docker exec nghia-master bash -lc 'timeout 1 bash -c ": </dev/tcp/127.0.0.1/10000"' >/dev/null 2>&1; then
            break
        fi
        if [ "$attempt" -eq "$hive_timeout_seconds" ]; then
            echo "FAIL: HiveServer2 Thrift chưa lắng nghe sau ${hive_timeout_seconds}s." >&2
            docker exec nghia-master tail -n 100 /opt/hive/logs/hiveserver2.log 2>&1 || true
            return 1
        fi
        sleep 1
    done

    echo "HiveServer2 Thrift đang lắng nghe; kiểm tra JDBC SHOW DATABASES..."
    if ! jdbc_output="$(docker exec nghia-master su hadoopnghia -s /bin/bash -c "timeout 60s /opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/default -e 'SHOW DATABASES;'" 2>&1)"; then
        echo "FAIL: HiveServer2 không hoàn tất truy vấn JDBC SHOW DATABASES." >&2
        printf '%s\n' "$jdbc_output" >&2
        docker exec nghia-master tail -n 100 /opt/hive/logs/hiveserver2.log 2>&1 || true
        return 1
    fi
    printf '%s\n' "$jdbc_output"
}

if ! report="$(hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -report' 2>&1)"; then
    echo "FAIL: không lấy được HDFS report." >&2
    printf '%s\n' "$report" >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
live_datanodes="$(printf '%s\n' "$report" | awk -F'[()]' '/Live datanodes/ { print $2; exit }')"
live_datanodes="${live_datanodes:-0}"

if ! yarn_nodes="$(hadoop_exec '/opt/hadoop/bin/yarn node -list -all' 2>&1)"; then
    echo "FAIL: không lấy được YARN node list." >&2
    printf '%s\n' "$yarn_nodes" >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
running_aliases="$(running_yarn_aliases "$yarn_nodes")"
running_nodemanagers="$(printf '%s\n' "$running_aliases" | awk 'NF { count++ } END { print count+0 }')"

datanode_rows="$(parse_live_datanodes "$report")"
read -r unique_endpoints unique_hostnames < <(printf '%s\n' "$datanode_rows" | awk -F '\t' '
    NF == 5 && $1 != "-" { endpoints[$1] = 1; if ($2 != "-") hostnames[$2] = 1 }
    END {
        for (value in endpoints) endpoint_count++
        for (value in hostnames) hostname_count++
        print endpoint_count + 0, hostname_count + 0
    }
')
bad_endpoints="$(printf '%s\n' "$datanode_rows" | awk -F '\t' '
    NF == 5 && $1 != "-" {
        host = $1
        sub(/:[0-9]+$/, "", host)
        if (host ~ /^127\./ || host == "localhost" || host ~ /^localhost\./ ||
            host == "0.0.0.0" || host == "::1" || host == "[::1]" || host == "::" || host == "[::]") print $1
    }
')"
bad_datanode_state="$(datanode_state_issues "$datanode_rows")"

expected_worker_mappings="$(docker exec nghia-master /bin/bash -c '
    for slot in "$@"; do
        hostname_var="WORKER${slot}_HOSTNAME"
        ip_var="WORKER${slot}_IP"
        printf "%s\t%s\tworker%s\n" "${!hostname_var:-}" "${!ip_var:-}" "$slot"
    done
' -- "${expected_slots[@]}" 2>/dev/null || true)"
configured_worker_count="$(printf '%s\n' "$expected_worker_mappings" | awk -F '\t' 'NF == 3 && $1 != "" && $2 != "" { count++ } END { print count+0 }')"
reported_worker_hostnames="$(printf '%s\n' "$datanode_rows" | awk -F '\t' 'NF == 5 && $2 != "-" { print $2 }' | sort -u)"
missing_worker_hostnames=""
bad_hostname_resolutions=""
unreachable_datanodes=""
missing_nodemanager_aliases=""

while IFS=$'\t' read -r expected_hostname expected_ip expected_alias; do
    [ -n "$expected_hostname" ] || continue
    if ! printf '%s\n' "$reported_worker_hostnames" | grep -Fxq "$expected_hostname"; then
        missing_worker_hostnames="${missing_worker_hostnames} ${expected_hostname}"
    fi
    resolved_ip="$(docker exec nghia-master getent ahostsv4 "$expected_hostname" 2>/dev/null | awk 'NR == 1 { print $1; exit }' || true)"
    if ! hostname_maps_to_expected_ip "$resolved_ip" "$expected_ip"; then
        bad_hostname_resolutions="${bad_hostname_resolutions} ${expected_hostname}=${resolved_ip:-unresolved} (expected ${expected_ip})"
    fi
    if ! docker exec nghia-master timeout 3 bash -c ": </dev/tcp/${expected_ip}/9866" >/dev/null 2>&1; then
        unreachable_datanodes="${unreachable_datanodes} ${expected_hostname}:${expected_ip}:9866"
    fi
    if ! yarn_alias_is_running "$running_aliases" "$expected_alias"; then
        missing_nodemanager_aliases="${missing_nodemanager_aliases} ${expected_alias}"
    fi
done <<< "$expected_worker_mappings"

echo "Mode: ${target}"
echo "Expected workers: ${expected} (slots: ${expected_slots[*]}; YARN aliases: $(printf 'worker%s ' "${expected_slots[@]}"))"
echo "Live DataNodes: ${live_datanodes}"
echo "Unique DataNode endpoints: ${unique_endpoints}"
echo "Unique DataNode hostnames: ${unique_hostnames}"
echo "Configured worker mappings: ${configured_worker_count}"
echo "DataNodes with contact/capacity/block-report issues: $(printf '%s\n' "$bad_datanode_state" | awk 'NF { count++ } END { print count+0 }')"
echo "Running NodeManagers (logical aliases): ${running_nodemanagers}"

if [ "$live_datanodes" -ne "$expected" ] ||
   [ "$running_nodemanagers" -ne "$expected" ] ||
   [ "$unique_endpoints" -ne "$expected" ] ||
   [ "$unique_hostnames" -ne "$expected" ] ||
   [ "$configured_worker_count" -ne "$expected" ] ||
   [ -n "$bad_endpoints" ] ||
   [ -n "$bad_datanode_state" ] ||
   [ -n "$missing_worker_hostnames" ] ||
   [ -n "$bad_hostname_resolutions" ] ||
   [ -n "$unreachable_datanodes" ] ||
   [ -n "$missing_nodemanager_aliases" ]; then
    echo "FAIL: số Worker hoặc endpoint/hostname DataNode/NodeManager không đạt yêu cầu." >&2
    [ -z "$bad_endpoints" ] || echo "Loopback/wildcard DataNode endpoints:${bad_endpoints}" >&2
    [ -z "$bad_datanode_state" ] || { echo "DataNode capacity/block-report issue:" >&2; printf '%s\n' "$bad_datanode_state" >&2; }
    [ -z "$missing_worker_hostnames" ] || echo "Thiếu hostname DataNode đã cấu hình:${missing_worker_hostnames}" >&2
    [ -z "$bad_hostname_resolutions" ] || echo "Hostname không phân giải tới IP cấu hình:${bad_hostname_resolutions}" >&2
    [ -z "$unreachable_datanodes" ] || echo "Không truy cập được DataNode transfer port:${unreachable_datanodes}" >&2
    [ -z "$missing_nodemanager_aliases" ] || echo "Thiếu NodeManager RUNNING cho alias:${missing_nodemanager_aliases}" >&2
    echo "--- Live DataNode endpoint / hostname ---" >&2
    printf '%s\n' "$datanode_rows" >&2
    echo "--- HDFS report ---" >&2
    printf '%s\n' "$report" >&2
    echo "--- YARN node list ---" >&2
    printf '%s\n' "$yarn_nodes" >&2
    docker logs nghia-master --tail 120 2>&1 || true
    safe_mode_status="$(hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -safemode get' 2>&1 || true)"
    if printf '%s\n' "$safe_mode_status" | grep -Fq 'Safe mode is ON'; then
        echo "--- SafeMode is ON; read-only fsck diagnostic follows ---" >&2
        printf '%s\n' "$safe_mode_status" >&2
        run_fsck_diagnostic
    fi
    exit 1
fi

if ! wait_for_safemode_off; then
    exit 1
fi
if ! fsck_report="$(hadoop_exec "timeout ${fsck_timeout_seconds}s /opt/hadoop/bin/hdfs fsck / -files -blocks -locations" 2>&1)"; then
    echo "FAIL: hdfs fsck / thất bại hoặc timeout; không thực hiện thay đổi HDFS." >&2
    printf '%s\n' "$fsck_report" >&2
    exit 1
fi
if fsck_has_damage "$fsck_report"; then
    echo "FAIL: fsck / phát hiện block thiếu/hỏng; dừng trước Hive hoặc Spark." >&2
    printf '%s\n' "$fsck_report" | grep -Ei 'Status:|MISSING BLOCKS|CORRUPT BLOCKS|Total blocks:|Total files:' >&2 || true
    exit 1
fi
printf '%s\n' "$fsck_report" | grep -Ei 'Status:|MISSING BLOCKS|CORRUPT BLOCKS|Total blocks:|Total files:' || true

if [ "$target" = pilot ]; then
    echo "PASS: pilot HDFS/YARN health gate (${expected} DataNodes, ${expected} NodeManagers, SafeMode OFF, fsck clean). Hive/Spark were not started or tested."
    exit 0
fi

if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -mkdir -p /tmp /tmp/hive /user/hive/warehouse /nhom14/input/word /nhom14/input/hive_sales'; then
    echo "FAIL: không tạo được thư mục HDFS; dừng trước chmod/Hive." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -test -s /nhom14/input/word/description.txt'; then
    echo "FAIL: HDFS input /nhom14/input/word/description.txt không tồn tại hoặc rỗng." >&2
    echo "Chỉ nạp khi xác nhận đích chưa tồn tại; không dùng -put -f." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod 1777 /tmp'; then
    echo "FAIL: không cập nhật được quyền HDFS /tmp." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if ! hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod 777 /tmp/hive /user/hive/warehouse /nhom14 /nhom14/input /nhom14/input/word /nhom14/input/hive_sales'; then
    echo "FAIL: không cập nhật được quyền thư mục HDFS của Hive/bài thực hành." >&2
    docker logs nghia-master --tail 120 2>&1 || true
    exit 1
fi
if [ "$hive_required" = true ] && ! wait_for_hiveserver2; then
    exit 1
fi

echo "PASS: ${expected} DataNode, ${expected} NodeManager (YARN aliases), SafeMode OFF, fsck clean; HiveServer2 JDBC checked."
