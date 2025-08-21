#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu cài auto-redeploy..."

# ==== Tạo auto-redeploy.sh (script gọi lại setup.sh) ====
cat <<'EOF' > /root/auto-redeploy.sh
#!/bin/bash
set -euo pipefail

SCRIPT_PATH="/root/setup.sh"
LOG_FILE="/var/log/auto-redeploy.log"

echo "[$(date)] Auto redeploy starting..." | tee -a $LOG_FILE

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[$(date)] ERROR: $SCRIPT_PATH không tồn tại!" | tee -a $LOG_FILE
  exit 1
fi

bash "$SCRIPT_PATH" >> $LOG_FILE 2>&1
echo "[$(date)] Auto redeploy hoàn tất." | tee -a $LOG_FILE
EOF

chmod +x /root/auto-redeploy.sh

# ==== Tạo systemd service ====
cat <<'EOF' > /etc/systemd/system/auto-redeploy.service
[Unit]
Description=Auto run setup.sh after reboot
After=network.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/auto-redeploy.sh

[Install]
WantedBy=multi-user.target
EOF

# ==== Enable service ====
systemctl daemon-reload
systemctl enable auto-redeploy.service

echo "[INFO] Hoàn tất. Sau mỗi reboot, /root/setup.sh sẽ tự động chạy lại."
