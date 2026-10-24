#!/bin/bash
set -euo pipefail

safemode_timeout_seconds=180
fsck_timeout_seconds=180
service_timeout_seconds=180
hive_log_dir="/opt/hive/logs"

fail() {
    echo "ERROR: $*" >&2
    echo "--- Hive logs ---" >&2
    tail -n 80 "$hive_log_dir/metastore.log" "$hive_log_dir/hiveserver2.log" 2>/dev/null || true
    exit 1
}

hadoop_exec() {
    su hadoopnghia -s /bin/bash -c "export HADOOP_CONF_DIR='${HADOOP_CONF_DIR:-/opt/hadoop/etc/hadoop}'; $1"
}

port_is_open() {
    timeout 1 bash -c ": </dev/tcp/127.0.0.1/$1" >/dev/null 2>&1
}

configured_derby_path() {
    python3 - "${HIVE_CONF_DIR:-${HIVE_HOME:-/opt/hive}/conf}/hive-site.xml" <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
values = [
    (property.findtext("value") or "").strip()
    for property in root.findall("property")
    if (property.findtext("name") or "").strip() == "javax.jdo.option.ConnectionURL"
]
prefix = "jdbc:derby:;databaseName="
if len(values) != 1 or not values[0].startswith(prefix):
    raise SystemExit("Expected exactly one embedded Derby ConnectionURL")
database_path = values[0][len(prefix):].split(";", 1)[0]
if not os.path.isabs(database_path) or not re.fullmatch(r"/[A-Za-z0-9_./-]+", database_path):
    raise SystemExit("Derby databaseName must be a safe absolute path")
normalized_path = os.path.normpath(database_path)
if normalized_path != database_path:
    raise SystemExit("Derby databaseName must not contain path traversal or redundant components")
print(database_path)
PY
}

classify_metastore_state() {
    local database_dir="$1" mount_dir="$2" first_entry
    [ -d "$mount_dir" ] || return 2
    if ! first_entry="$(find "$mount_dir" -mindepth 1 -maxdepth 1 -print -quit)"; then
        return 2
    fi
    if [ -z "$first_entry" ]; then
        printf 'empty\n'
    elif [ -d "$database_dir" ] && [ ! -L "$database_dir" ] &&
         [ -s "$database_dir/service.properties" ] && [ ! -L "$database_dir/service.properties" ]; then
        printf 'existing\n'
    else
        printf 'invalid\n'
    fi
}

if [ "${START_HIVE_SERVICES_TEST_MODE:-}" = "metastore-state" ]; then
    if ! configured_db_dir="$(configured_derby_path)"; then
        echo "FAIL: actual hive-site.xml Derby ConnectionURL could not be parsed." >&2
        exit 1
    fi
    [ "$configured_db_dir" = /opt/hive/metastore_db/metastore_db ] || {
        echo "FAIL: unexpected configured Derby path: ${configured_db_dir}." >&2
        exit 1
    }
    [ "$(dirname -- "$configured_db_dir")" = /opt/hive/metastore_db ] || {
        echo "FAIL: Derby path parent does not match the Compose metastore mount." >&2
        exit 1
    }

    fixture_root="$(mktemp -d)"
    trap 'rm -rf -- "$fixture_root"' EXIT
    empty_mount="$fixture_root/empty"
    existing_mount="$fixture_root/existing"
    invalid_mount="$fixture_root/invalid"
    mkdir -p "$empty_mount" "$existing_mount/metastore_db" "$invalid_mount"
    printf 'derby.serviceProtocol=6\n' > "$existing_mount/metastore_db/service.properties"
    printf 'unrecognized metadata\n' > "$invalid_mount/README"

    [ "$(classify_metastore_state "$empty_mount/metastore_db" "$empty_mount")" = empty ] || {
        echo "FAIL: an empty metastore mount was not classified for first initialization." >&2
        exit 1
    }
    [ "$(classify_metastore_state "$existing_mount/metastore_db" "$existing_mount")" = existing ] || {
        echo "FAIL: recognized Derby metadata was not classified as existing." >&2
        exit 1
    }
    [ "$(classify_metastore_state "$invalid_mount/metastore_db" "$invalid_mount")" = invalid ] || {
        echo "FAIL: non-empty unrecognized metastore contents were accepted." >&2
        exit 1
    }
    echo "PASS: hive-site.xml resolves to the Compose Derby mount; fixtures distinguish existing, empty, and invalid state."
    exit 0
fi

wait_for_port() {
    local port="$1" name="$2" attempt
    for attempt in $(seq 1 "$service_timeout_seconds"); do
        port_is_open "$port" && return 0
        sleep 1
    done
    fail "${name} chưa lắng nghe cổng ${port} sau ${service_timeout_seconds}s."
}

if [ "${NODE_ROLE:-}" != "master" ]; then
    fail "Chạy script này bên trong Master (NODE_ROLE=master)."
fi

if ! hive_derby_db_dir="$(configured_derby_path)"; then
    fail "Không đọc được Derby ConnectionURL hợp lệ từ hive-site.xml; dừng để tránh khởi tạo sai thư mục metadata."
fi
hive_db_dir="$(dirname -- "$hive_derby_db_dir")"
if ! awk -v target="$hive_db_dir" '$5 == target { mounted = 1 } END { exit !mounted }' /proc/self/mountinfo; then
    fail "Thư mục Derby ${hive_derby_db_dir} không nằm ngay trong metastore mount của Compose (${hive_db_dir}); dừng trước mọi thay đổi HDFS/Hive."
fi

if ! bash -lc '
    set -e
    for port in 9000 8032; do timeout 1 bash -c ": </dev/tcp/127.0.0.1/$port" >/dev/null 2>&1; done
    jps_output="$(su hadoopnghia -s /bin/bash -c "jps")"
    printf "%s\n" "$jps_output" | grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+NameNode([[:space:]]|$)"
    printf "%s\n" "$jps_output" | grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+ResourceManager([[:space:]]|$)"
'; then
    fail "NameNode hoặc ResourceManager chưa sẵn sàng."
fi

if ! safe_mode="$(hadoop_exec "timeout ${safemode_timeout_seconds}s /opt/hadoop/bin/hdfs dfsadmin -safemode wait" 2>&1)"; then
    echo "FAIL: SafeMode chưa tắt sau ${safemode_timeout_seconds}s." >&2
    echo "--- SafeMode ---" >&2
    hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -safemode get' 2>&1 || true
    echo "--- HDFS report ---" >&2
    hadoop_exec '/opt/hadoop/bin/hdfs dfsadmin -report' 2>&1 || true
    echo "--- Read-only fsck diagnostic (60s max) ---" >&2
    hadoop_exec 'timeout 60s /opt/hadoop/bin/hdfs fsck / -files -blocks -locations' 2>&1 || true
    fail "Không khởi động Hive khi HDFS còn trong SafeMode."
fi
printf '%s\n' "$safe_mode"

if ! fsck_report="$(hadoop_exec "timeout ${fsck_timeout_seconds}s /opt/hadoop/bin/hdfs fsck / -files -blocks -locations" 2>&1)"; then
    printf '%s\n' "$fsck_report" >&2
    fail "HDFS fsck thất bại hoặc timeout; Hive chưa được khởi động."
fi
if printf '%s\n' "$fsck_report" | grep -Eiq 'Status:[[:space:]]*CORRUPT|MISSING BLOCKS:?[[:space:]]*[1-9][0-9]*|CORRUPT BLOCKS:?[[:space:]]*[1-9][0-9]*'; then
    printf '%s\n' "$fsck_report" | grep -Ei 'Status:|MISSING BLOCKS|CORRUPT BLOCKS|Total blocks:|Total files:' >&2 || true
    fail "fsck phát hiện block thiếu/hỏng; Hive chưa được khởi động."
fi
printf '%s\n' "$fsck_report" | grep -Ei 'Status:|MISSING BLOCKS|CORRUPT BLOCKS|Total blocks:|Total files:' || true

if ! metastore_state="$(classify_metastore_state "$hive_derby_db_dir" "$hive_db_dir")"; then
    fail "Không thể kiểm tra nội dung metastore mount; dừng để bảo toàn metadata."
fi
if [ "$metastore_state" = invalid ]; then
    fail "Metastore mount không rỗng nhưng không có Derby service.properties nhận dạng được; dừng, không chạy schema init."
fi

# Create the expected working directories only after the read-only health gate passes.
hadoop_exec '/opt/hadoop/bin/hdfs dfs -mkdir -p /tmp /tmp/hive /user/hive/warehouse /nhom14/input/word /nhom14/input/hive_sales' ||
    fail "Không tạo được thư mục HDFS cần thiết cho Hive."
hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod 1777 /tmp' || fail "Không đặt được quyền HDFS cho /tmp."
hadoop_exec '/opt/hadoop/bin/hdfs dfs -chmod 777 /tmp/hive /user/hive/warehouse /nhom14 /nhom14/input /nhom14/input/word /nhom14/input/hive_sales' ||
    fail "Không đặt được quyền HDFS cho thư mục Hive/bài thực hành."

mkdir -p "$hive_log_dir"
chown hadoopnghia:hadoopnghia "$hive_log_dir"
hadoop_exec "test -w '$hive_db_dir' -a -w '$hive_log_dir'" || fail "User hadoopnghia không ghi được Hive state/log directories."

if [ "$metastore_state" = existing ]; then
    echo "Hive Derby metadata đã tồn tại; giữ nguyên, không chạy schematool initSchema."
else
    echo "Metastore mount mới và trống; khởi tạo schema Derby lần đầu sau health gate."
    hadoop_exec '/opt/hive/bin/schematool -dbType derby -initSchema' || fail "Không khởi tạo được schema Hive Derby."
fi

start_service() {
    local name="$1" port="$2" process_pattern="$3" command="$4" log_file="$5"
    if port_is_open "$port"; then
        echo "${name} đã lắng nghe cổng ${port}; không tạo tiến trình mới."
        return
    fi
    if pgrep -f "$process_pattern" >/dev/null 2>&1; then
        echo "${name} đã có tiến trình; chờ cổng ${port} thay vì tạo tiến trình trùng."
    else
        echo "Khởi động ${name}..."
        hadoop_exec "nohup ${command} > '${log_file}' 2>&1 </dev/null &" || fail "Không khởi chạy được ${name}."
    fi
    wait_for_port "$port" "$name"
}

start_service "Hive Metastore" 9083 '[o]rg.apache.hadoop.hive.metastore.HiveMetaStore' \
    '/opt/hive/bin/hive --service metastore' "$hive_log_dir/metastore.log"
start_service "HiveServer2" 10000 '[o]rg.apache.hive.service.server.HiveServer2' \
    '/opt/hive/bin/hiveserver2' "$hive_log_dir/hiveserver2.log"

if ! jdbc_output="$(hadoop_exec "timeout 60s /opt/hive/bin/beeline -u jdbc:hive2://nghia-master:10000/default -e 'SHOW DATABASES;'" 2>&1)"; then
    printf '%s\n' "$jdbc_output" >&2
    fail "HiveServer2 không hoàn tất JDBC SHOW DATABASES trong 60s."
fi
printf '%s\n' "$jdbc_output"
echo "PASS: Hive Metastore and HiveServer2 are listening; JDBC SHOW DATABASES succeeded."
