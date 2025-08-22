#!/bin/bash
set -euo pipefail

echo "=== [CLEANUP] Bắt đầu dọn dẹp triệt để Docker & auto-spawn ==="

# 1. Tắt restart policy tất cả container
echo "[INFO] Tắt restart policy container..."
for c in $(docker ps -aq); do
  docker update --restart=no "$c" || true
done

# 2. Stop & remove toàn bộ container
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Xóa toàn bộ container..."
  docker rm -f $(docker ps -aq) || true
else
  echo "[INFO] Không có container nào."
fi

# 3. Xóa toàn bộ images
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Xóa toàn bộ images..."
  docker rmi -f $(docker images -q) || true
else
  echo "[INFO] Không có images nào."
fi

# 4. Giữ nguyên volumes (không xoá dữ liệu)

# 5. Disable & remove systemd services/timers đáng ngờ
echo "[INFO] Tắt và xóa systemd service/timer liên quan..."
for svc in \
  docker-apps.service \
  al2023-docker-setup.service \
  docker-boot-reset.service \
  docker-weekly-reset.service; do
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f /etc/systemd/system/$svc || true
done

for tmr in \
  docker-apps-boot.timer \
  al2023-docker-setup.timer \
  docker-boot-reset.timer \
  docker-weekly-reset.timer; do
  systemctl disable --now "$tmr" 2>/dev/null || true
  rm -f /etc/systemd/system/$tmr || true
done

# 6. Reload systemd
systemctl daemon-reload
systemctl reset-failed

echo "=== [CLEANUP] Hoàn tất. Sẽ reboot sau 5 giây... ==="
sleep 5
reboot
