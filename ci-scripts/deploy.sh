#!/usr/bin/env bash
set -euo pipefail

TARGET_HOST=${1:-"192.168.1.84"}
TARGET_USER=${2:-"ubuntu"}
DEB_PATH=${3:-"packaging/dist/camera-app_*.deb"}

# copy deb
scp ${DEB_PATH} ${TARGET_USER}@${TARGET_HOST}:/tmp/
ssh ${TARGET_USER}@${TARGET_HOST} "sudo dpkg -i /tmp/$(basename ${DEB_PATH}) || true; sudo systemctl daemon-reload; sudo systemctl restart camera-app.service || true"
