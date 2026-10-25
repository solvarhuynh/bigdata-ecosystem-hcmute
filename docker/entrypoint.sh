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

require_port() {
    local name="$1"
    local value="$2"
    local port
    require_value "$name" "$value"
    [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || fail "${name} phải là TCP port hợp lệ dạng chuẩn."
    port="$((10#$value))"
    [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || fail "${name} phải nằm trong khoảng 1024-65535."
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

assert_reverse_hostname() {
    local ip="$1"
    local expected_hostname="$2"
    local actual_hostname
    actual_hostname="$(getent hosts "$ip" | awk 'NR == 1 { print $2; exit }')"
    [ "${actual_hostname,,}" = "${expected_hostname,,}" ] ||
        fail "IP ${ip} reverse-resolve thành '${actual_hostname:-không phân giải}', mong đợi ${expected_hostname}."
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

find_datanode_registration() {
    local report="$1"
    local expected_hostname="$2"
    local expected_xfer_port="$3"
    local started_at="$4"
    local registration endpoint hostname last_contact contact_epoch endpoint_host

    registration="$(printf '%s\n' "$report" | awk -v expected="$expected_hostname" -v expected_port="$expected_xfer_port" '
        function emit_record() {
            endpoint_port = endpoint
            sub(/^.*:/, "", endpoint_port)
            if (in_live && endpoint != "" && endpoint_port == expected_port && hostname == expected && last_contact != "") {
                print endpoint "\t" hostname "\t" last_contact
            }
        }
        /^Live datanodes/ { in_live = 1; next }
        /^(Dead|Decommissioning|Decommissioned|In maintenance) datanodes/ { emit_record(); in_live = 0; next }
        /^Name:/ {
            emit_record()
            endpoint = $2
            hostname = ""
            last_contact = ""
            next
        }
        /^Hostname:/ { hostname = $2; next }
        /^Last contact:/ {
            last_contact = $0
            sub(/^Last contact:[[:space:]]*/, "", last_contact)
        }
        END { emit_record() }
    ')"
    [ -n "$registration" ] || return 1
    while IFS=$'\t' read -r endpoint hostname last_contact; do
        contact_epoch="$(date -u -d "$last_contact" +%s 2>/dev/null || echo 0)"
        [ "$contact_epoch" -ge "$started_at" ] || continue

        endpoint_host="${endpoint%:*}"
        if [[ "$endpoint_host" =~ ^127\. ]] ||
           [[ "${endpoint_host,,}" == localhost || "${endpoint_host,,}" == localhost.* ]] ||
           [[ "$endpoint_host" == "0.0.0.0" || "$endpoint_host" == "::" || "$endpoint_host" == "[::]" || "$endpoint_host" == "::1" || "$endpoint_host" == "[::1]" ]]; then
            continue
        fi

        printf '%s\t%s\t%s\n' "$endpoint" "$hostname" "$last_contact"
        return 0
    done <<< "$registration"
    return 1
}

if [ "${ENTRYPOINT_TEST_MODE:-}" = "datanode-registration" ]; then
    test_started_at="$(date -u +%s)"
    fresh_contact="$(date -u -d "@${test_started_at}" '+%a %b %d %H:%M:%S UTC %Y')"
    mixed_report="$(cat <<EOF
Live datanodes (2):
Name: 172.19.0.1:19866 (worker1/172.19.0.1)
Hostname: khang-worker
Last contact: ${fresh_contact}
Name: 172.19.0.1:19868 (worker3/172.19.0.1)
Hostname: hongkhoa-worker
Last contact: ${fresh_contact}
EOF
)"
    worker3_only="$(cat <<EOF
Live datanodes (1):
Name: 172.19.0.1:19868 (worker3/172.19.0.1)
Hostname: hongkhoa-worker
Last contact: ${fresh_contact}
EOF
)"
    worker1_registration="$(find_datanode_registration "$mixed_report" khang-worker 19866 "$((test_started_at - 1))")" ||
        fail "Fixture test: worker1 record was not selected."
    [[ "$worker1_registration" == $'172.19.0.1:19866\tkhang-worker\t'* ]] ||
        fail "Fixture test: worker1 matched the wrong DataNode record."
    worker3_registration="$(find_datanode_registration "$worker3_only" hongkhoa-worker 19868 "$((test_started_at - 1))")" ||
        fail "Fixture test: worker3-only record was not selected for its own hostname."
    [[ "$worker3_registration" == $'172.19.0.1:19868\t'* ]] ||
        fail "Fixture test: worker3-only fixture returned the wrong record."
    if find_datanode_registration "$worker3_only" khang-worker 19866 "$((test_started_at - 1))" >/dev/null; then
        fail "Fixture test: worker3 record incorrectly satisfied worker1 registration."
    fi

    wrong_port_report="$(printf 'Live datanodes (1):\nName: 172.19.0.1:19867 (worker1/172.19.0.1)\nHostname: khang-worker\nLast contact: %s\n' "$fresh_contact")"
    if find_datanode_registration "$wrong_port_report" khang-worker 19866 "$((test_started_at - 1))" >/dev/null; then
        fail "Fixture test: registration with the wrong transfer port was accepted."
    fi

    expect_no_registration() {
        local report="$1" hostname="$2" expected_port="$3" started_at="$4" description="$5"
        if find_datanode_registration "$report" "$hostname" "$expected_port" "$started_at" >/dev/null; then
            fail "Fixture test: accepted ${description}."
        fi
    }
    for endpoint in 127.0.0.1:19866 0.0.0.0:19866 localhost:19866 ::1:19866 '[::]:19866' '[::1]:19866'; do
        endpoint_report="$(printf 'Live datanodes (1):\nName: %s (worker1/127.0.0.1)\nHostname: khang-worker\nLast contact: %s\n' "$endpoint" "$fresh_contact")"
        expect_no_registration "$endpoint_report" khang-worker 19866 "$((test_started_at - 1))" "non-routable endpoint ${endpoint}"
    done
    wrong_hostname_report="$(printf 'Live datanodes (1):\nName: 172.19.0.1:19866 (worker1/172.19.0.1)\nHostname: other-worker\nLast contact: %s\n' "$fresh_contact")"
    expect_no_registration "$wrong_hostname_report" khang-worker 19866 "$((test_started_at - 1))" "a mismatched hostname"
    stale_contact="$(date -u -d '@0' '+%a %b %d %H:%M:%S UTC %Y')"
    stale_report="$(printf 'Live datanodes (1):\nName: 172.19.0.1:19866 (worker1/172.19.0.1)\nHostname: khang-worker\nLast contact: %s\n' "$stale_contact")"
    expect_no_registration "$stale_report" khang-worker 19866 "$((test_started_at - 1))" "a stale Last contact"
    expect_no_registration $'Live datanodes (1):\nName: 172.19.0.1:19866 (worker1/172.19.0.1)\nHostname: khang-worker' khang-worker 19866 "$((test_started_at - 1))" "a record missing Last contact"
    expect_no_registration $'Live datanodes (1):\nName: 172.19.0.1:19866 (worker1/172.19.0.1)\nLast contact: ' khang-worker 19866 "$((test_started_at - 1))" "a record missing hostname"
    expect_no_registration $'Live datanodes (1):\nName:\nHostname: khang-worker\nLast contact: ' khang-worker 19866 "$((test_started_at - 1))" "a record missing endpoint and Last contact"
    echo "PASS: DataNode fixtures verify shared NAT IPs with unique transfer ports, hostname matching, freshness and invalid endpoints."
    exit 0
fi

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
    if ! python3 - "$source_conf" "$runtime_conf" "$NODE_HOSTNAME" "$WORKER_LOGICAL_NAME" "$WORKER_XFER_PORT" <<'PY'
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

source, destination, hostname, logical_name, xfer_port = sys.argv[1:]
shutil.copytree(source, destination, dirs_exist_ok=True)

def set_properties(xml_path, updates):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    if root.tag != "configuration":
        raise SystemExit(f"{xml_path.name} root must be <configuration>")
    for key, configured_value in updates.items():
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
        value.text = configured_value
    tree.write(xml_path, encoding="UTF-8", xml_declaration=True)

set_properties(Path(destination) / "hdfs-site.xml", {
    "dfs.datanode.hostname": hostname,
    "dfs.datanode.address": f"0.0.0.0:{xfer_port}",
})
set_properties(Path(destination) / "yarn-site.xml", {
    "yarn.nodemanager.hostname": logical_name,
    "yarn.nodemanager.address": f"{logical_name}:8041",
    "yarn.nodemanager.bind-host": "0.0.0.0",
    "yarn.nodemanager.webapp.address": f"{logical_name}:8042",
})
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
    [ "$datanode_address" = "0.0.0.0:${WORKER_XFER_PORT}" ] || fail "dfs.datanode.address=${datanode_address}; mong đợi 0.0.0.0:${WORKER_XFER_PORT}."
    [ "$datanode_http" = "0.0.0.0:9864" ] || fail "dfs.datanode.http.address=${datanode_http}; mong đợi 0.0.0.0:9864."
    [ "$datanode_ipc" = "0.0.0.0:9867" ] || fail "dfs.datanode.ipc.address=${datanode_ipc}; mong đợi 0.0.0.0:9867."
    [ "$client_hostname" = "true" ] || fail "dfs.client.use.datanode.hostname phải là true."
    [ "$datanode_hostname_mode" = "true" ] || fail "dfs.datanode.use.datanode.hostname phải là true."
    echo "HDFS effective config: logical=${WORKER_LOGICAL_NAME}, hostname=${datanode_hostname}, bind=${datanode_address}, HTTP=${datanode_http}, IPC=${datanode_ipc}, clientHostname=${client_hostname}, datanodeHostname=${datanode_hostname_mode}"
}

wait_for_datanode_registration() {
    local started_at="$1"
    local attempt report registration endpoint
    for attempt in $(seq 1 24); do
        report="$(run_as_hadoop "/opt/hadoop/bin/hdfs dfsadmin -report" 2>&1)" || report=""
        if registration="$(find_datanode_registration "$report" "$NODE_HOSTNAME" "$WORKER_XFER_PORT" "$started_at")"; then
            endpoint="${registration%%$'\t'*}"
            echo "DataNode registered: logical=${WORKER_LOGICAL_NAME}, hostname=${NODE_HOSTNAME}, endpoint=${endpoint}"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: NameNode chưa xác nhận registration mới cho hostname=${NODE_HOSTNAME} và transfer port=${WORKER_XFER_PORT} sau 120 giây." >&2
    echo "Trong Docker Desktop, IP endpoint có thể là IP NAT dùng chung; hostname phải phân giải tới WORKER_IP và transfer port phải duy nhất." >&2
    echo "Kiểm tra endpoint ${NODE_HOSTNAME}:${WORKER_XFER_PORT} có truy cập được qua host port đã publish hay không." >&2
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
        if printf '%s\n' "$nodes" | awk -v alias="$WORKER_LOGICAL_NAME" '$2 == "RUNNING" { node = $1; sub(/:[0-9]+$/, "", node); if (node == alias) found = 1 } END { exit !found }'; then
            echo "NodeManager registered: logical=${WORKER_LOGICAL_NAME}, hostname=${NODE_HOSTNAME}"
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
MASTER_START_PHASE="${MASTER_START_PHASE:-core}"
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
if [ "$NODE_ROLE" = "master" ]; then
    case "$MASTER_START_PHASE" in
        core|full) ;;
        *) fail "MASTER_START_PHASE phải là core hoặc full, nhận được: ${MASTER_START_PHASE}" ;;
    esac
fi

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
    port_var="WORKER${slot}_XFER_PORT"
    ip_value="${!ip_var:-}"
    hostname_value="${!hostname_var:-}"
    port_value="${!port_var:-}"
    require_ip "$ip_var" "$ip_value"
    require_hostname "$hostname_var" "$hostname_value"
    require_port "$port_var" "$port_value"
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
        port_var="WORKER${slot}_XFER_PORT"
        other_port_var="WORKER${other_slot}_XFER_PORT"
        other_hostname_value="${!other_hostname_var}"
        [ "${!ip_var}" != "${!other_ip_var}" ] || fail "${ip_var} và ${other_ip_var} bị trùng."
        [ "$hostname_lower" != "${other_hostname_value,,}" ] || fail "${hostname_var} và ${other_hostname_var} bị trùng."
        [ "${!port_var}" != "${!other_port_var}" ] || fail "${port_var} và ${other_port_var} phải khác nhau để DataNode endpoint luôn duy nhất."
    done
done

if [ "$NODE_ROLE" = "worker" ]; then
    require_value WORKER_LOGICAL_NAME "${WORKER_LOGICAL_NAME:-}"
    require_ip WORKER_IP "${WORKER_IP:-}"
    case "$WORKER_LOGICAL_NAME" in
        worker1) expected_ip="$WORKER1_IP"; expected_hostname="$WORKER1_HOSTNAME"; expected_xfer_port="$WORKER1_XFER_PORT" ;;
        worker2) expected_ip="$WORKER2_IP"; expected_hostname="$WORKER2_HOSTNAME"; expected_xfer_port="$WORKER2_XFER_PORT" ;;
        worker3) expected_ip="$WORKER3_IP"; expected_hostname="$WORKER3_HOSTNAME"; expected_xfer_port="$WORKER3_XFER_PORT" ;;
        worker4) expected_ip="$WORKER4_IP"; expected_hostname="$WORKER4_HOSTNAME"; expected_xfer_port="$WORKER4_XFER_PORT" ;;
        *) fail "WORKER_LOGICAL_NAME phải là worker1, worker2, worker3 hoặc worker4." ;;
    esac
    [ "$WORKER_IP" = "$expected_ip" ] || fail "WORKER_IP không khớp IP của ${WORKER_LOGICAL_NAME}."
    [ "$NODE_HOSTNAME" = "$expected_hostname" ] || fail "NODE_HOSTNAME không khớp hostname của ${WORKER_LOGICAL_NAME}."
    require_port WORKER_XFER_PORT "${WORKER_XFER_PORT:-}"
    [ "$WORKER_XFER_PORT" = "$expected_xfer_port" ] || fail "WORKER_XFER_PORT không khớp cổng đã gán cho ${WORKER_LOGICAL_NAME}."
fi

echo "=========================================================="
echo "Khởi động Node trong cụm BigData-N14"
echo "Role: ${NODE_ROLE}"
echo "Hostname: ${NODE_HOSTNAME}"
echo "User: hadoopnghia / root"
echo "=========================================================="

# Mỗi alias được kiểm tra riêng để không ghi thêm dòng khi container restart.
if [ "$NODE_ROLE" = "master" ]; then
    master_resolution="127.0.0.1"
else
    master_resolution="$MASTER_IP"
    worker_container_ip="$(hostname -I | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }')"
    require_ip WORKER_CONTAINER_IP "$worker_container_ip"
fi
add_host_entry "$master_resolution" nghia-master
add_host_entry "$master_resolution" "$MASTER_HOSTNAME"
for slot in $worker_slots; do
    ip_var="WORKER${slot}_IP"
    hostname_var="WORKER${slot}_HOSTNAME"
    alias="worker${slot}"
    alias_ip="${!ip_var}"
    hostname_ip="${!ip_var}"
    if [ "$NODE_ROLE" = "worker" ] && [ "$WORKER_LOGICAL_NAME" = "$alias" ]; then
        alias_ip="$worker_container_ip"
        if [ "${!hostname_var,,}" = "$alias" ]; then hostname_ip="$worker_container_ip"; fi
    fi
    add_host_entry "$alias_ip" "$alias"
    if [ "${!hostname_var,,}" != "$alias" ]; then
        add_host_entry "$hostname_ip" "${!hostname_var}"
    fi
done
assert_host_resolution nghia-master "$master_resolution"
assert_host_resolution "$MASTER_HOSTNAME" "$master_resolution"
for slot in $worker_slots; do
    ip_var="WORKER${slot}_IP"
    hostname_var="WORKER${slot}_HOSTNAME"
    alias="worker${slot}"
    alias_ip="${!ip_var}"
    hostname_ip="${!ip_var}"
    if [ "$NODE_ROLE" = "worker" ] && [ "$WORKER_LOGICAL_NAME" = "$alias" ]; then
        alias_ip="$worker_container_ip"
        if [ "${!hostname_var,,}" = "$alias" ]; then hostname_ip="$worker_container_ip"; fi
    fi
    assert_host_resolution "$alias" "$alias_ip"
    assert_host_resolution "${!hostname_var}" "$hostname_ip"
done
if [ "$NODE_ROLE" = "worker" ]; then
    assert_reverse_hostname "$worker_container_ip" "$WORKER_LOGICAL_NAME"
fi

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
    wait_for_tcp 9870 NameNode-Web

    echo "Khởi động ResourceManager..."
    run_as_hadoop "/opt/hadoop/bin/yarn --daemon start resourcemanager"
    wait_for_tcp 8032 ResourceManager
    wait_for_tcp 8088 ResourceManager-Web

    if [ "$MASTER_START_PHASE" = "full" ]; then
        echo "Master phase=full: chờ HDFS health gate rồi mới khởi động Hive."
        if bash /start_hive_services.sh; then
            echo "Master full services đã sẵn sàng: NameNode, ResourceManager, Metastore và HiveServer2 JDBC."
        else
            echo "ERROR: Hive chưa sẵn sàng; NameNode và ResourceManager vẫn tiếp tục chạy. Xem log và chạy lại /start_hive_services.sh sau health gate."
        fi
    else
        echo "Master core services đã sẵn sàng: NameNode và ResourceManager."
        echo "Hive chưa được khởi động; sau check_cluster.sh pilot, chạy: docker exec nghia-master bash /start_hive_services.sh"
    fi
else
    echo ">>> Đang khởi động WORKER NODE (${WORKER_LOGICAL_NAME}) <<<"
    echo "Worker mapping: logical=${WORKER_LOGICAL_NAME}, hostname=${NODE_HOSTNAME}, hostIP=${WORKER_IP}, containerIP=${worker_container_ip}, xferPort=${WORKER_XFER_PORT}"
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
