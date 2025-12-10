#!/usr/bin/env bash
set -euo pipefail

NETWORK="camera-net"

if ! podman network inspect "${NETWORK}" >/dev/null 2>&1; then
  echo "Creating network ${NETWORK}"
  podman network create "${NETWORK}"
else
  echo "Network ${NETWORK} already exists"
fi

echo "Starting services..."
podman-compose up -d --build
