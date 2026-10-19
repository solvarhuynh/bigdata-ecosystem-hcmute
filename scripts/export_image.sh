#!/bin/bash
set -e

IMAGE_NAME="bigdata-cluster:1.0"
OUTPUT_TAR="bigdata-cluster-1.0.tar"

echo "=== [BigData-N14] Đang export Docker Image $IMAGE_NAME ra file $OUTPUT_TAR ==="
docker save "$IMAGE_NAME" -o "$OUTPUT_TAR"

echo "=== Export thành công! File: $OUTPUT_TAR ==="
echo "Gửi file này cho 4 thành viên Worker. Các bạn dùng lệnh sau để nạp:"
echo "  docker load -i $OUTPUT_TAR"