#!/usr/bin/env bash
# Root bootstrap for dashboard-requested build-service installation.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
id herdr >/dev/null
release=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Bootstrap only the request worker. The build executor remains opt-in.
install -d -o root -g root -m 0755 /var/lib/herdr-build-install
install -d -o herdr -g herdr -m 0700 /var/lib/herdr-build-install-requests
install -o root -g root -m 0755 "$release/install/build-service-install.py" /usr/local/sbin/herdr-build-service-install
cat >/etc/systemd/system/herdr-build-install.service <<'EOF'
[Unit]
Description=Install the Herdr build service when requested
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/herdr-build-service-install
TimeoutStartSec=660
UMask=0022
EOF
cat >/etc/systemd/system/herdr-build-install.path <<'EOF'
[Unit]
Description=Watch for authenticated build-service installation requests
[Path]
PathExists=/var/lib/herdr-build-install-requests/request.json
Unit=herdr-build-install.service
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now herdr-build-install.path
