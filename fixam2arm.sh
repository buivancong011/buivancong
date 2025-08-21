#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu fix auto-redeploy..."

# ==== Đảm bảo script chính tồn tại ====
if [ ! -f "/root/caidatarmam2" ]; then
  echo "[WARN] /root/caidatarmam2 chưa có -> copy từ repo"
  curl -fsSL https://raw.githubusercontent.com/buivancong011/buivancong/refs/heads/main/caidatarmam2 -o /root/caidatarmam2
  chmod +x /root/caidatarmam2
fi

# ==== Tạo auto-redeploy.sh (gọi lại caidatarmam2) ====
cat <<'EOF' > /root/auto-redeploy.sh
#!/bin/bash
set -euo pipefail

SCRIPT_PATH="/root/caidatarmam2"
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
Description=Auto run caidatarmam2 after reboot
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

echo "[INFO] Hoàn tất. Sau reboot, /root/caidatarmam2 sẽ tự động chạy lại."
