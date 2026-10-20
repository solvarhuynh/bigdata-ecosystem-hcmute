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
    local a b c d extra octet
    require_value "$name" "$value"
    IFS=. read -r a b c d extra <<< "$value"
    [ -z "$extra" ] || fail "${name} phải là IPv4 hợp lệ: ${value}."
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || fail "${name} phải là IPv4 hợp lệ: ${value}."
        [ "$((10#$octet))" -le 255 ] || fail "${name} phải là IPv4 hợp lệ: ${value}."
    done
}

require_hostname() {
    local name="$1"
    local value="$2"
    require_value "$name" "$value"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "${name} không phải hostname hợp lệ: ${value}."
}

add_host_entry() {
    local ip="$1"
    shift
    [ -n "$ip" ] && [ -n "$1" ] || return 0
    if ! awk -v ip="$ip" -v alias="$1" '$1 == ip { for (i = 2; i <= NF; i++) if ($i == alias) found = 1 } END { exit(found ? 0 : 1) }' /etc/hosts; then
        echo "$ip $*" >> /etc/hosts
    fi
}

run_as_hadoop() {
    su hadoopnghia -s /bin/bash -c "$1"
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

if [ "$NODE_ROLE" = "worker" ]; then
    # Bao gồm cả ánh xạ các worker còn lại khi chạy trên từng máy vật lý.
    for slot in 1 2 3 4; do
        ip_var="WORKER${slot}_IP"
        hostname_var="WORKER${slot}_HOSTNAME"
        add_host_entry "${!ip_var:-}" "worker${slot}"
        add_host_entry "${!ip_var:-}" "${!hostname_var:-}"
    done
    add_host_entry "$WORKER_IP" "$WORKER_LOGICAL_NAME"
    add_host_entry "$WORKER_IP" "$NODE_HOSTNAME"
fi

# Chế độ kiểm tra nhẹ, không khởi động daemon và không chạm dữ liệu HDFS.
if [ "${VALIDATE_ONLY:-false}" = "true" ]; then
    for slot in $worker_slots; do
        getent hosts "worker${slot}"
        hostname_var="WORKER${slot}_HOSTNAME"
        getent hosts "${!hostname_var}"
    done
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
    echo "Khởi động DataNode..."
    run_as_hadoop "/opt/hadoop/bin/hdfs --daemon start datanode"
    wait_for_jps DataNode
    echo "Khởi động NodeManager..."
    run_as_hadoop "/opt/hadoop/bin/yarn --daemon start nodemanager"
    wait_for_jps NodeManager
    echo "Worker ${WORKER_LOGICAL_NAME} đã sẵn sàng: DataNode và NodeManager đang chạy."
fi

exec tail -f /dev/null
