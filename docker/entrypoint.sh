#!/bin/bash
set -e

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="$2"
    [ -n "$value" ] || fail "Thiếu biến bắt buộc ${name}."
    case "$value" in
        *'<'*|*'>'*|CHANGEME|TODO) fail "${name} đang chứa giá trị placeholder không hợp lệ." ;;
    esac
}

require_ip() {
    local name="$1"
    local value="$2"
    local a b c d extra octet first_octet
    require_value "$name" "$value"
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "${name} phải là IPv4 hợp lệ: ${value}."
    IFS=. read -r a b c d extra <<< "$value"
    [ -z "$extra" ] || fail "${name} phải là IPv4 hợp lệ: ${value}."
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || fail "${name} phải là IPv4 hợp lệ: ${value}."
        [[ "$octet" == "0" || "$octet" != 0* ]] || fail "${name} phải dùng IPv4 dạng chuẩn, không có số 0 ở đầu octet: ${value}."
        [ "$((10#$octet))" -le 255 ] || fail "${name} phải là IPv4 hợp lệ: ${value}."
    done
    [ "$value" != "0.0.0.0" ] || fail "${name} không được là địa chỉ bind 0.0.0.0."
    first_octet="$((10#$a))"
    [ "$first_octet" -ne 0 ] || fail "${name} không được thuộc dải 0.0.0.0/8."
    [ "$first_octet" -ne 127 ] || fail "${name} không được là địa chỉ loopback."
    [ "$first_octet" -lt 224 ] || fail "${name} phải là địa chỉ IPv4 unicast."
}

require_hostname() {
    local name="$1"
    local value="$2"
    require_value "$name" "$value"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "${name} không phải hostname hợp lệ: ${value}."
    case "${value,,}" in
        localhost|localhost.*) fail "${name} không được dùng hostname localhost." ;;
    esac
}

add_host_entry() {
    local ip="$1"
    local alias="$2"
    local hosts_tmp
    [ -n "$ip" ] && [ -n "$alias" ] || return 0
    hosts_tmp="$(mktemp)"
    awk -v alias="$alias" '
        /^[[:space:]]*#/ { print; next }
        {
            updated = $1
            removed = 0
            for (i = 2; i <= NF; i++) {
                if ($i == alias) removed = 1
                else updated = updated " " $i
            }
            if (!removed) print $0
            else if (updated != $1) print updated
        }
    ' /etc/hosts > "$hosts_tmp"
    cat "$hosts_tmp" > /etc/hosts
    rm -f -- "$hosts_tmp"
    printf '%s %s\n' "$ip" "$alias" >> /etc/hosts
}

assert_host_resolution() {
    local alias="$1"
    local expected_ip="$2"
    local actual_ip
    actual_ip="$(getent ahostsv4 "$alias" | awk 'NR == 1 { print $1; exit }')"
    [ "$actual_ip" = "$expected_ip" ] ||
        fail "Tên ${alias} phân giải thành '${actual_ip:-không phân giải}', mong đợi ${expected_ip}."
}

run_as_hadoop() {
    su hadoopnghia -s /bin/bash -c "export HADOOP_CONF_DIR='${HADOOP_CONF_DIR}'; $1"
}

wait_for_tcp() {
    local port="$1"
    local service_name="$2"
    local attempt

    for attempt in $(seq 1 60); do
        if timeout 1 bash -c ": </dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1 ||
           timeout 1 bash -c ": </dev/tcp/${NODE_HOSTNAME}/${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "ERROR: ${service_name} chưa lắng nghe cổng ${port}." >&2
    return 1
}

wait_for_remote_tcp() {
    local host="$1"
    local port="$2"
    local service_name="$3"
    local attempt
    for attempt in $(seq 1 60); do
        if timeout 1 bash -c ": </dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "ERROR: ${service_name} chưa truy cập được tại ${host}:${port}." >&2
    return 1
}

wait_for_jps() {
    local process_name="$1"
    local attempt
    local jps_output
    for attempt in $(seq 1 30); do
        jps_output="$(run_as_hadoop "jps")"
        if printf '%s\n' "$jps_output" |
            grep -Eq "^[[:space:]]*[0-9]+[[:space:]]+${process_name}([[:space:]]|$)"; then
            return 0
        fi
        sleep 1
    done
    echo "ERROR: Hadoop process ${process_name} chưa khởi động." >&2
    printf '%s\n' "$jps_output" >&2
    return 1
}

prepare_worker_hadoop_conf() {
    local source_conf="$HADOOP_CONF_DIR"
    local runtime_conf="/tmp/bigdata-hadoop-conf"
    [ -f "${source_conf}/hdfs-site.xml" ] || fail "Thiếu ${source_conf}/hdfs-site.xml."
    mkdir -p "$runtime_conf"
    if ! python3 - "$source_conf" "$runtime_conf" "$NODE_HOSTNAME" <<'PY'
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

source, destination, hostname = sys.argv[1:]
shutil.copytree(source, destination, dirs_exist_ok=True)
xml_path = Path(destination) / "hdfs-site.xml"
tree = ET.parse(xml_path)
root = tree.getroot()
if root.tag != "configuration":
    raise SystemExit("hdfs-site.xml root must be <configuration>")

key = "dfs.datanode.hostname"
properties = [p for p in root.findall("property") if p.findtext("name", "").strip() == key]
if len(properties) > 1:
    raise SystemExit(f"duplicate Hadoop property: {key}")
if properties:
    value = properties[0].find("value")
    if value is None:
        value = ET.SubElement(properties[0], "value")
else:
    prop = ET.SubElement(root, "property")
    ET.SubElement(prop, "name").text = key
    value = ET.SubElement(prop, "value")
value.text = hostname
tree.write(xml_path, encoding="UTF-8", xml_declaration=True)
PY
    then
        fail "Không thể tạo Hadoop runtime config cho ${NODE_HOSTNAME}."
    fi
    HADOOP_CONF_DIR="$runtime_conf"
    export HADOOP_CONF_DIR
}

validate_worker_hadoop_conf() {
    local datanode_hostname datanode_address datanode_http datanode_ipc
    local client_hostname datanode_hostname_mode
    datanode_hostname="$(run_as_hadoop "/opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.hostname")"
    datanode_address="$(run_as_hadoop "/opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.address")"
    datanode_http="$(run_as_hadoop "/opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.http.address")"
    datanode_ipc="$(run_as_hadoop "/opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.ipc.address")"
    client_hostname="$(run_as_hadoop "/opt/hadoop/bin/hdfs getconf -confKey dfs.client.use.datanode.hostname")"
    datanode_hostname_mode="$(run_as_hadoop "/opt/hadoop/bin/hdfs getconf -confKey dfs.datanode.use.datanode.hostname")"
    [ "$datanode_hostname" = "$NODE_HOSTNAME" ] || fail "dfs.datanode.hostname=${datanode_hostname}; mong đợi ${NODE_HOSTNAME}."
    [ "$datanode_address" = "0.0.0.0:9866" ] || fail "dfs.datanode.address=${datanode_address}; mong đợi 0.0.0.0:9866."
    [ "$datanode_http" = "0.0.0.0:9864" ] || fail "dfs.datanode.http.address=${datanode_http}; mong đợi 0.0.0.0:9864."
    [ "$datanode_ipc" = "0.0.0.0:9867" ] || fail "dfs.datanode.ipc.address=${datanode_ipc}; mong đợi 0.0.0.0:9867."
    [ "$client_hostname" = "true" ] || fail "dfs.client.use.datanode.hostname phải là true."
    [ "$datanode_hostname_mode" = "true" ] || fail "dfs.datanode.use.datanode.hostname phải là true."
    echo "HDFS effective config: logical=${WORKER_LOGICAL_NAME}, hostname=${datanode_hostname}, bind=${datanode_address}, HTTP=${datanode_http}, IPC=${datanode_ipc}, clientHostname=${client_hostname}, datanodeHostname=${datanode_hostname_mode}"
}

wait_for_datanode_registration() {
    local started_at="$1"
    local attempt report registration endpoint last_contact contact_epoch endpoint_host
    for attempt in $(seq 1 24); do
        report="$(run_as_hadoop "/opt/hadoop/bin/hdfs dfsadmin -report" 2>&1)" || report=""
        registration="$(printf '%s\n' "$report" | awk -v expected="$NODE_HOSTNAME" '
            /^Name:/ { address = $2 }
            /^Hostname:/ { hostname = $2 }
            /^Last contact:/ && hostname == expected {
                contact = $0
                sub(/^Last contact:[[:space:]]*/, "", contact)
                print address "\t" contact
                exit
            }
        ')"
        endpoint="${registration%%$'\t'*}"
        last_contact="${registration#*$'\t'}"
        contact_epoch="$(date -u -d "$last_contact" +%s 2>/dev/null || echo 0)"
        if [ -n "$endpoint" ]; then
            endpoint_host="${endpoint%:*}"
            case "$endpoint_host" in
                127.*|localhost|0.0.0.0|::1|\[::1\]) ;;
                *) if [ "$endpoint_host" = "$WORKER_IP" ] && [ "$contact_epoch" -ge "$started_at" ]; then
                    echo "DataNode registered: logical=${WORKER_LOGICAL_NAME}, hostname=${NODE_HOSTNAME}, endpoint=${endpoint}"
                    return 0
                fi ;;
            esac
        fi
        sleep 5
    done
    echo "ERROR: NameNode chưa xác nhận đăng ký mới cho hostname=${NODE_HOSTNAME}, endpoint=${WORKER_IP}:9866 sau 120 giây." >&2
    echo "--- HDFS report ---" >&2
    printf '%s\n' "$report" >&2
    echo "--- DataNode process ---" >&2
    run_as_hadoop "jps" >&2 || true
    echo "--- DataNode log gần nhất ---" >&2
    local datanode_log
    datanode_log="$(find /opt/hadoop/logs -maxdepth 1 -type f -iname '*datanode*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }')"
    if [ -n "$datanode_log" ]; then tail -n 100 "$datanode_log" >&2; fi
    return 1
}

wait_for_nodemanager_registration() {
    local attempt nodes
    for attempt in $(seq 1 24); do
        nodes="$(run_as_hadoop "/opt/hadoop/bin/yarn node -list -all" 2>&1)" || nodes=""
        if printf '%s\n' "$nodes" | awk -v host="$NODE_HOSTNAME" '$0 ~ /RUNNING/ && index($0, host) { found = 1 } END { exit !found }'; then
            echo "NodeManager registered: hostname=${NODE_HOSTNAME}"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: NodeManager process chạy nhưng ResourceManager chưa đăng ký hostname=${NODE_HOSTNAME} sau 120 giây." >&2
    printf '%s\n' "$nodes" >&2
    return 1
}

NODE_ROLE="${NODE_ROLE:-}"
NODE_HOSTNAME="${NODE_HOSTNAME:-}"
CLUSTER_SIZE="${CLUSTER_SIZE:-4}"
require_value NODE_ROLE "$NODE_ROLE"
require_hostname NODE_HOSTNAME "$NODE_HOSTNAME"
case "$NODE_ROLE" in
    master|worker) ;;
    *) fail "NODE_ROLE phải là master hoặc worker, nhận được: ${NODE_ROLE}" ;;
esac
case "$CLUSTER_SIZE" in
    1|4) ;;
    *) fail "CLUSTER_SIZE phải là 1 hoặc 4, nhận được: ${CLUSTER_SIZE}" ;;
esac

require_ip MASTER_IP "${MASTER_IP:-}"
require_hostname MASTER_HOSTNAME "${MASTER_HOSTNAME:-}"

if [ "$CLUSTER_SIZE" = "1" ]; then
    worker_slots="1"
else
    worker_slots="1 2 3 4"
fi

for slot in $worker_slots; do
    ip_var="WORKER${slot}_IP"
    hostname_var="WORKER${slot}_HOSTNAME"
    ip_value="${!ip_var:-}"
    hostname_value="${!hostname_var:-}"
    require_ip "$ip_var" "$ip_value"
    require_hostname "$hostname_var" "$hostname_value"
done

for slot in $worker_slots; do
    ip_var="WORKER${slot}_IP"
    hostname_var="WORKER${slot}_HOSTNAME"
    hostname_value="${!hostname_var}"
    hostname_lower="${hostname_value,,}"
    [ "${!ip_var}" != "$MASTER_IP" ] || fail "${ip_var} không được trùng MASTER_IP."
    [ "$hostname_lower" != "${MASTER_HOSTNAME,,}" ] || fail "${hostname_var} không được trùng MASTER_HOSTNAME."
    [ "$hostname_lower" != "nghia-master" ] || fail "${hostname_var} không được trùng alias Master nghia-master."
    case "${MASTER_HOSTNAME,,}" in
        worker1|worker2|worker3|worker4) fail "MASTER_HOSTNAME không được trùng bí danh logic ${MASTER_HOSTNAME}." ;;
    esac
    for alias_slot in $worker_slots; do
        if [ "$alias_slot" -ne "$slot" ] && [ "$hostname_lower" = "worker${alias_slot}" ]; then
            fail "${hostname_var} không được trùng bí danh logic worker${alias_slot} của node khác."
        fi
    done
    for other_slot in $worker_slots; do
        [ "$other_slot" -gt "$slot" ] || continue
        other_ip_var="WORKER${other_slot}_IP"
        other_hostname_var="WORKER${other_slot}_HOSTNAME"
        other_hostname_value="${!other_hostname_var}"
        [ "${!ip_var}" != "${!other_ip_var}" ] || fail "${ip_var} và ${other_ip_var} bị trùng."
        [ "$hostname_lower" != "${other_hostname_value,,}" ] || fail "${hostname_var} và ${other_hostname_var} bị trùng."
    done
done

if [ "$NODE_ROLE" = "worker" ]; then
    require_value WORKER_LOGICAL_NAME "${WORKER_LOGICAL_NAME:-}"
    require_ip WORKER_IP "${WORKER_IP:-}"
    case "$WORKER_LOGICAL_NAME" in
        worker1) expected_ip="$WORKER1_IP"; expected_hostname="$WORKER1_HOSTNAME" ;;
        worker2) expected_ip="$WORKER2_IP"; expected_hostname="$WORKER2_HOSTNAME" ;;
        worker3) expected_ip="$WORKER3_IP"; expected_hostname="$WORKER3_HOSTNAME" ;;
        worker4) expected_ip="$WORKER4_IP"; expected_hostname="$WORKER4_HOSTNAME" ;;
        *) fail "WORKER_LOGICAL_NAME phải là worker1, worker2, worker3 hoặc worker4." ;;
    esac
    [ "$WORKER_IP" = "$expected_ip" ] || fail "WORKER_IP không khớp IP của ${WORKER_LOGICAL_NAME}."
    [ "$NODE_HOSTNAME" = "$expected_hostname" ] || fail "NODE_HOSTNAME không khớp hostname của ${WORKER_LOGICAL_NAME}."
fi

echo "=========================================================="
echo "Khởi động Node trong cụm BigData-N14"
echo "Role: ${NODE_ROLE}"
echo "Hostname: ${NODE_HOSTNAME}"
echo "User: hadoopnghia / root"
echo "=========================================================="

# Mỗi alias được kiểm tra riêng để không ghi thêm dòng khi container restart.
add_host_entry "$MASTER_IP" nghia-master
add_host_entry "$MASTER_IP" "$MASTER_HOSTNAME"
for slot in $worker_slots; do
    ip_var="WORKER${slot}_IP"
    hostname_var="WORKER${slot}_HOSTNAME"
    add_host_entry "${!ip_var}" "worker${slot}"
    add_host_entry "${!ip_var}" "${!hostname_var}"
done
assert_host_resolution nghia-master "$MASTER_IP"
assert_host_resolution "$MASTER_HOSTNAME" "$MASTER_IP"
for slot in $worker_slots; do
    ip_var="WORKER${slot}_IP"
    hostname_var="WORKER${slot}_HOSTNAME"
    assert_host_resolution "worker${slot}" "${!ip_var}"
    assert_host_resolution "${!hostname_var}" "${!ip_var}"
done

if [ "$NODE_ROLE" = "worker" ]; then
    prepare_worker_hadoop_conf
    validate_worker_hadoop_conf
fi

# Chế độ kiểm tra nhẹ, không khởi động daemon và không chạm dữ liệu HDFS.
if [ "${VALIDATE_ONLY:-false}" = "true" ]; then
    if [ "$NODE_ROLE" = "worker" ]; then
        echo "PASS: hostname mapping and effective HDFS configuration validated; services were not started."
    else
        echo "PASS: hostname mapping validated; services were not started."
    fi
    exit 0
fi

ssh-keygen -A
service ssh start
if ! pgrep -x sshd >/dev/null; then
    fail "sshd không khởi động thành công."
fi
echo "SSH daemon đã được kích hoạt trên cổng 22."

if [ "$NODE_ROLE" = "master" ]; then
    echo ">>> Đang thiết lập và khởi động MASTER NODE (${NODE_HOSTNAME}) <<<"

    if [ ! -d "/opt/hadoop/hdfs/namenode/current" ]; then
        fail "NameNode chưa được format; dừng để bảo vệ dữ liệu. Chỉ khởi tạo thủ công sau khi xác nhận volume mới và trống."
    fi
    echo "NameNode metadata đã tồn tại, bỏ qua format."

    echo "Khởi động NameNode..."
    run_as_hadoop "/opt/hadoop/bin/hdfs --daemon start namenode"
    wait_for_tcp 9000 NameNode

    echo "Khởi động ResourceManager..."
    run_as_hadoop "/opt/hadoop/bin/yarn --daemon start resourcemanager"
    wait_for_tcp 8032 ResourceManager

    if run_as_hadoop "/opt/hadoop/bin/hdfs dfsadmin -safemode get" | grep -q 'Safe mode is OFF'; then
        run_as_hadoop "/opt/hadoop/bin/hdfs dfs -mkdir -p /tmp /tmp/hive /user/hive/warehouse /test_bigdata/input /test_bigdata/hive_sales"
        run_as_hadoop "/opt/hadoop/bin/hdfs dfs -chmod 1777 /tmp"
        run_as_hadoop "/opt/hadoop/bin/hdfs dfs -chmod 777 /tmp/hive /user/hive/warehouse /test_bigdata /test_bigdata/input /test_bigdata/hive_sales"
    else
        echo "DataNode chưa đủ để thoát SafeMode; tạo thư mục HDFS sẽ do check_cluster.sh thực hiện sau."
    fi

    hive_db_dir="/opt/hive/metastore_db"
    hive_derby_db_dir="$hive_db_dir/metastore_db"
    hive_log_dir="/opt/hive/logs"

    mkdir -p "$hive_db_dir" "$hive_log_dir"
    chown -R hadoopnghia:hadoopnghia "$hive_db_dir" "$hive_log_dir"

    run_as_hadoop "test -w '$hive_db_dir' -a -w '$hive_log_dir'"

    if [ -f "$hive_derby_db_dir/service.properties" ]; then
        echo "Hive Metastore schema đã tồn tại, bỏ qua khởi tạo."
    elif [ -e "$hive_derby_db_dir" ]; then
        fail "Thư mục Hive Derby đã tồn tại nhưng thiếu service.properties; dừng để tránh ghi đè dữ liệu."
    else
        echo "Khởi tạo Hive Metastore schema Derby lần đầu..."
        run_as_hadoop "/opt/hive/bin/schematool -dbType derby -initSchema"
    fi

    echo "Khởi động Hive Metastore..."
    run_as_hadoop "nohup /opt/hive/bin/hive --service metastore > '$hive_log_dir/metastore.log' 2>&1 </dev/null &"
    wait_for_tcp 9083 Hive-Metastore

    echo "Khởi động HiveServer2..."
    run_as_hadoop "nohup /opt/hive/bin/hiveserver2 > '$hive_log_dir/hiveserver2.log' 2>&1 </dev/null &"
    echo "Master core services đã sẵn sàng: NameNode, ResourceManager và Hive Metastore đang lắng nghe."
    echo "HiveServer2 được khởi chạy; kiểm tra JDBC sau khi HDFS thoát SafeMode bằng scripts/check_cluster.sh."
else
    echo ">>> Đang khởi động WORKER NODE (${WORKER_LOGICAL_NAME}) <<<"
    echo "Worker mapping: logical=${WORKER_LOGICAL_NAME}, hostname=${NODE_HOSTNAME}, ip=${WORKER_IP}"
    wait_for_remote_tcp nghia-master 9000 NameNode-RPC
    echo "Khởi động DataNode..."
    datanode_started_at="$(date -u +%s)"
    run_as_hadoop "/opt/hadoop/bin/hdfs --daemon start datanode"
    wait_for_jps DataNode
    echo "DataNode process started; chờ NameNode xác nhận đăng ký..."
    wait_for_datanode_registration "$datanode_started_at"
    wait_for_remote_tcp nghia-master 8032 ResourceManager-RPC
    echo "Khởi động NodeManager..."
    run_as_hadoop "/opt/hadoop/bin/yarn --daemon start nodemanager"
    wait_for_jps NodeManager
    echo "NodeManager process started; chờ ResourceManager xác nhận đăng ký..."
    wait_for_nodemanager_registration
    echo "Worker ${WORKER_LOGICAL_NAME} đã đăng ký DataNode và NodeManager."
fi

exec tail -f /dev/null
