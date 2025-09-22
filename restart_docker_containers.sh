#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/docker_restart.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] ==== Restart toàn bộ container Docker ====" | tee -a "$LOG_FILE"

# Kiểm tra Docker có cài chưa
if ! command -v docker &>/dev/null; then
    echo "[$DATE] ❌ Docker chưa được cài đặt. Thoát." | tee -a "$LOG_FILE"
    exit 1
fi

# Lấy danh sách container đang chạy
RUNNING_CONTAINERS=$(docker ps -q)

if [ -z "$RUNNING_CONTAINERS" ]; then
    echo "[$DATE] ⚠️ Không có container nào đang chạy." | tee -a "$LOG_FILE"
    exit 0
fi

# Restart toàn bộ container
for cid in $RUNNING_CONTAINERS; do
    cname=$(docker inspect --format='{{.Name}}' "$cid" | sed 's/^\/\(.*\)/\1/')
    echo "[$DATE] 🔄 Restart container: $cname ($cid)" | tee -a "$LOG_FILE"
    docker restart "$cid" >/dev/null
done

echo "[$DATE] ✅ Hoàn tất restart toàn bộ container." | tee -a "$LOG_FILE"
