#!/bin/bash
set -e

IMAGE_NAME="bigdata-cluster:1.0"

echo "=== [BigData-N14] Đang build Docker Image: $IMAGE_NAME ==="
docker build --progress=plain -t "$IMAGE_NAME" -f docker/Dockerfile .

echo "=== Build Docker Image $IMAGE_NAME thành công! ==="
