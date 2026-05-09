#!/usr/bin/env bash
set -euo pipefail

IMAGE_PREFIX="localhost/van3twin"

echo "==> Stopping and removing van3twin containers..."
docker compose down --remove-orphans 2>/dev/null || true

echo "==> Removing van3twin images..."
docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep "^${IMAGE_PREFIX}:" \
  | xargs -r docker rmi -f

echo "==> Pruning dangling build cache and layers..."
docker builder prune -f
docker image prune -f

echo "Done."
