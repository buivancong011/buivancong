#!/bin/bash
set -euo pipefail

echo "[INFO] Weekly reboot script started..."

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] Script phải chạy bằng root."
  exit 1
fi

# Ghi log lại để sau này kiểm tra
LOG_FILE="/var/log/weekly-reboot.log"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Weekly reboot trigger" | tee -a "$LOG_FILE"

# Thông báo và reboot
echo "[INFO] Rebooting system in 5s..."
sleep 5
reboot
