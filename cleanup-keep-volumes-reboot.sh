#!/bin/bash
set -euo pipefail

echo "=== [CLEANUP] Bắt đầu dọn dẹp Docker + systemd + scripts ==="

# 0. Start Docker trước để có thể xóa container/images
echo "[INFO] Start Docker..."
systemctl start docker || true
echo "[INFO] Chờ 10 giây cho Docker khởi động..."
sleep 10

if systemctl is-active --quiet docker; then
  echo "[OK] Docker đã chạy."
else
  echo "[WARN] Docker chưa chạy -> bỏ qua phần Docker."
fi

echo "[INFO] Enable Docker để auto-start khi reboot..."
systemctl enable docker || true

# 1. Tắt restart policy container
echo "[INFO] Tắt restart policy container..."
for c in $(docker ps -aq 2>/dev/null || true); do
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

# 4. Xóa toàn bộ volumes TRỪ myst-data1 và myst-data2
echo "[INFO] Đang xoá volumes (trừ myst-data1, myst-data2)..."
for vol in $(docker volume ls -q 2>/dev/null || true); do
  if [[ "$vol" != "myst-data1" && "$vol" != "myst-data2" ]]; then
    echo "  -> Xóa volume $vol"
    docker volume rm -f "$vol" || true
  fi
done
sleep 2

# 5. Xóa toàn bộ networks trừ mặc định
echo "[INFO] Xóa toàn bộ networks..."
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  docker network rm "$net" || true
done
sleep 2

# 6. Xóa cronjobs liên quan
echo "[INFO] Xóa toàn bộ cronjobs..."
rm -f /etc/cron.d/* || true

# 7. Xóa tất cả systemd services/timers do user thêm
echo "[INFO] Xóa tất cả systemd services/timers custom..."
for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do
  if [ -f "$f" ]; then
    svc=$(basename "$f")
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$f"
    echo "  -> Xóa $svc"
  fi
done
sleep 2

systemctl daemon-reload
systemctl reset-failed

# 8. Xóa tất cả file .sh trong /root
echo "[INFO] Xóa toàn bộ file .sh trong /root..."
rm -f /root/*.sh || true

# 9. Hoàn tất
echo "=== [CLEANUP] Hoàn tất. Reboot sau 5 giây... ==="
sleep 5
reboot
