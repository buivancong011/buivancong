#!/bin/bash
set -euo pipefail

echo "=== [CLEANUP] Bắt đầu dọn dẹp triệt để Docker & auto-spawn ==="

# 0. Start Docker trước, chờ ổn định rồi mới enable
echo "[INFO] Start Docker ngay..."
systemctl start docker
echo "[INFO] Chờ 10 giây cho Docker khởi động..."
sleep 10

# Kiểm tra Docker đã active chưa
if systemctl is-active --quiet docker; then
  echo "[OK] Docker đang chạy."
else
  echo "[ERROR] Docker chưa chạy sau 10 giây. Dừng script!"
  exit 1
fi

echo "[INFO] Enable Docker để auto-start sau reboot..."
systemctl enable docker

# 1. Tắt restart policy tất cả container
echo "[INFO] Tắt restart policy container..."
for c in $(docker ps -aq); do
  docker update --restart=no "$c" || true
done
sleep 2

# 2. Stop & remove toàn bộ container
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Xóa toàn bộ container..."
  docker rm -f $(docker ps -aq) || true
else
  echo "[INFO] Không có container nào."
fi
sleep 2

# 3. Xóa toàn bộ images
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Xóa toàn bộ images..."
  docker rmi -f $(docker images -q) || true
else
  echo "[INFO] Không có images nào."
fi
sleep 2

# 4. Xóa toàn bộ volumes trừ myst-data1 và myst-data2
echo "[INFO] Đang xoá toàn bộ volumes (trừ myst-data1, myst-data2)..."
for vol in $(docker volume ls -q); do
  if [[ "$vol" != "myst-data1" && "$vol" != "myst-data2" ]]; then
    echo "  -> Xóa volume $vol"
    docker volume rm -f "$vol" || true
    sleep 1
  fi
done
sleep 2

# 5. Disable & remove systemd services/timers đáng ngờ
echo "[INFO] Tắt và xóa systemd service/timer liên quan..."
for svc in \
  docker-apps.service \
  al2023-docker-setup.service \
  docker-boot-reset.service \
  docker-weekly-reset.service; do
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f /etc/systemd/system/$svc || true
  sleep 1
done

for tmr in \
  docker-apps-boot.timer \
  al2023-docker-setup.timer \
  docker-boot-reset.timer \
  docker-weekly-reset.timer; do
  systemctl disable --now "$tmr" 2>/dev/null || true
  rm -f /etc/systemd/system/$tmr || true
  sleep 1
done
sleep 2

# 6. Reload systemd
systemctl daemon-reload
systemctl reset-failed
sleep 2

# 7. Hoàn tất cleanup mới reboot
echo "=== [CLEANUP] Hoàn tất. Sẽ reboot sau 5 giây... ==="
sleep 5
reboot
