#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu cài đặt auto-redeploy..."

# ==== B1: Tải setup.sh (script chính) ====
# ⚠️ Thay link GitHub RAW của bạn vào đây
SETUP_URL="https://raw.githubusercontent.com/username/repo/main/setup.sh"
curl -fsSL $SETUP_URL -o /root/setup.sh
chmod +x /root/setup.sh

# ==== B2: Tạo auto-redeploy.sh ====
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

# ==== B3: Tạo systemd service ====
cat <<'EOF' > /etc/systemd/system/auto-redeploy.service
[Unit]
Description=Auto run setup.sh after reboot
After=network.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/auto-redeploy.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ==== B4: Enable service ====
systemctl daemon-reload
systemctl enable auto-redeploy.service

echo "[INFO] Cài đặt hoàn tất. Server sẽ auto redeploy sau reboot hoặc khi gọi /root/auto-redeploy.sh"
