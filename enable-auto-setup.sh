#!/bin/bash
set -euo pipefail

SERVICE_FILE="/etc/systemd/system/setup-redeploy.service"

echo "[INFO] Tạo systemd service để tự chạy /root/setup.sh sau reboot..."

cat <<EOF | sudo tee $SERVICE_FILE
[Unit]
Description=Auto run setup.sh after reboot
After=network.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/setup.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Cập nhật systemd và bật service
sudo systemctl daemon-reload
sudo systemctl enable setup-redeploy.service

echo "[INFO] Hoàn tất. Từ giờ sau mỗi reboot, /root/setup.sh sẽ tự động chạy."
