#!/usr/bin/env bash
set -euo pipefail

VERSION=${1:-"0.0.0-$(date +%Y%m%d%H%M%S)"}
PKGNAME="camera-app"
BUILD_DIR="./packaging/build"
DIST_DIR="./packaging/dist"

# cleanup
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${BUILD_DIR}/DEBIAN" "${BUILD_DIR}/usr/local/${PKGNAME}" "${DIST_DIR}"

# Copy runtime files (compose & helper scripts). Do NOT copy secrets/certs unless allowed by policy
cp -r podman-compose.yml "${BUILD_DIR}/usr/local/${PKGNAME}/"
cp -r ci-scripts "${BUILD_DIR}/usr/local/${PKGNAME}/"
# You can include service definition for systemd that calls /usr/local/camera-app/run.sh
cp -r backend mediamtx mosquitto flutter_frontend "${BUILD_DIR}/usr/local/${PKGNAME}/" || true

# Create a simple run script (will pull images and run podman-compose)
cat > "${BUILD_DIR}/usr/local/${PKGNAME}/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /usr/local/camera-app
# Ensure network exists
podman network inspect camera-net >/dev/null 2>&1 || podman network create camera-net
# You likely want to pull from registry in production; for dev use local images
podman-compose up -d
EOF
chmod +x "${BUILD_DIR}/usr/local/${PKGNAME}/run.sh"

# DEBIAN/control
cat > "${BUILD_DIR}/DEBIAN/control" <<EOF
Package: ${PKGNAME}
Version: ${VERSION}
Section: misc
Priority: optional
Architecture: arm64
Depends: podman, podman-compose
Maintainer: You <you@example.com>
Description: Camera application bundle (MediaMTX + Mosquitto + Backend + Frontend)
EOF

# Optional postinst script to run systemd unit or run script
cat > "${BUILD_DIR}/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
if command -v systemctl >/dev/null 2>&1; then
  # create simple systemd service to run the bundled run.sh
  cat > /etc/systemd/system/camera-app.service <<EOL
[Unit]
Description=Camera App (podman-compose)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/camera-app/run.sh
WorkingDirectory=/usr/local/camera-app

[Install]
WantedBy=multi-user.target
EOL
  systemctl daemon-reload
  systemctl enable --now camera-app.service || true
fi
EOF
chmod 755 "${BUILD_DIR}/DEBIAN/postinst"

# Build .deb
dpkg-deb --build "${BUILD_DIR}" "${DIST_DIR}/${PKGNAME}_${VERSION}_amd64.deb"
echo "Built ${DIST_DIR}/${PKGNAME}_${VERSION}_arm64.deb"
