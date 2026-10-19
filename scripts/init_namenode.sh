#!/bin/bash
set -e

target="${1:-}"
case "$target" in
    local)
        compose_file="docker/docker-compose.local.yml"
        service="nghia-master"
        volume_name="local_namenode"
        ;;
    master)
        compose_file="docker/docker-compose.master.yml"
        service="master"
        volume_name="master_namenode"
        ;;
    *)
        echo "Dùng: bash scripts/init_namenode.sh local|master" >&2
        exit 2
        ;;
esac

env_file_args=()
if [ "$target" = "master" ]; then
    test -f .env || { echo "ERROR: cần .env với IP/hostname thật của cụm master." >&2; exit 1; }
    env_file_args=(--env-file .env)
fi

if ! docker compose -f "$compose_file" "${env_file_args[@]}" config --quiet; then
    echo "ERROR: Compose không hợp lệ: $compose_file" >&2
    exit 1
fi

if ! docker compose -f "$compose_file" "${env_file_args[@]}" config --volumes | grep -qx "$volume_name"; then
    echo "ERROR: Compose không mount volume NameNode ${volume_name} như mong đợi." >&2
    exit 1
fi

if docker compose -f "$compose_file" "${env_file_args[@]}" ps --status running --services | grep -qx "$service"; then
    echo "ERROR: $service đang chạy; hãy dừng riêng container trước khi kiểm tra volume." >&2
    exit 1
fi

echo "Kiểm tra volume Compose ${volume_name} tại /opt/hadoop/hdfs/namenode..."
docker compose -f "$compose_file" "${env_file_args[@]}" run --rm --no-deps --entrypoint bash "$service" -lc '
    set -e
    dir=/opt/hadoop/hdfs/namenode
    test -d "$dir"
    test ! -e "$dir/current"
    if find "$dir" -mindepth 1 -print -quit | grep -q .; then
        echo "ERROR: thư mục NameNode không trống; không được format." >&2
        exit 1
    fi
    echo "Volume đúng và thư mục NameNode đang trống."
'

echo "Chỉ tiếp tục nếu bạn đã xác nhận volume ${volume_name} là mới và không chứa dữ liệu HDFS."
read -r -p "Gõ FORMAT-NAMENODE-${target} để xác nhận: " confirmation
if [ "$confirmation" != "FORMAT-NAMENODE-${target}" ]; then
    echo "Không xác nhận; không format NameNode."
    exit 1
fi

docker compose -f "$compose_file" "${env_file_args[@]}" run --rm --no-deps --entrypoint bash "$service" -lc '
    set -e
    dir=/opt/hadoop/hdfs/namenode
    test ! -e "$dir/current"
    if find "$dir" -mindepth 1 -print -quit | grep -q .; then
        echo "ERROR: volume đã thay đổi và không còn trống; hủy format." >&2
        exit 1
    fi
    chown -R hadoopnghia:hadoopnghia "$dir"
    su hadoopnghia -s /bin/bash -c "/opt/hadoop/bin/hdfs namenode -format -nonInteractive"
'

echo "Xác minh metadata NameNode sau khởi tạo..."
docker compose -f "$compose_file" "${env_file_args[@]}" run --rm --no-deps --entrypoint bash "$service" -lc '
    test -d /opt/hadoop/hdfs/namenode/current
    echo "NameNode metadata đã được tạo."
'
