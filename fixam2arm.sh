#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu fix auto-redeploy..."

# ==== Đảm bảo script chính tồn tại ====
if [ ! -f "/root/caidataamdam2" ]; then
  echo "[WARN] /root/caidataamdam2 chưa có -> copy từ repo"
  curl -fsSL https://raw.githubusercontent.com/buivancong011/buivancong/refs/heads/main/caidataamdam2 -o /root/caidataamdam2
  chmod +x /root/caidataamdam2
fi

# ==== Tạo auto-redeploy.sh (gọi lại caidataamdam2) ====
cat <<'EOF' > /root/auto-redeploy.sh
#!/bin/bash
set -euo pipefail

SCRIPT_PATH="/root/caidataamdam2"
LOG_FILE="/var/log/auto-redeploy.log"

echo "[$(date)] Auto redeploy starting..." | tee -a $LOG_FILE

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[$(date)] ERROR: $SCRIPT_PATH không tồn tại!" | tee -a $LOG_FILE
  exit 1
fi

/bin/bash "$SCRIPT_PATH" >> $LOG_FILE 2>&1
echo "[$(date)] Auto redeploy hoàn tất." | tee -a $LOG_FILE
EOF

chmod 755 /root/auto-redeploy.sh

# ==== Tạo systemd service ====
cat <<'EOF' > /etc/systemd/system/auto-redeploy.service
[Unit]
Description=Auto run caidataamdam2 after reboot
After=network.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /root/auto-redeploy.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ==== Enable service ====
systemctl daemon-reload
systemctl enable auto-redeploy.service

echo "[INFO] Hoàn tất. Sau reboot, /root/caidataamdam2 sẽ tự động chạy lại."
