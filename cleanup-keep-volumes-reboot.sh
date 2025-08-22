#!/bin/bash
set -euo pipefail

echo "=== [CLEANUP] Dọn dẹp Docker + auto-spawn (chặn tm1 tái tạo) ==="

# 0. Khởi động Docker
echo "[INFO] Khởi động Docker..."
systemctl start docker || true
sleep 10
systemctl enable docker || true
echo "[OK] Docker đã sẵn sàng."
sleep 2

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

# 6. Xóa cronjobs nghi ngờ
echo "[INFO] Xóa cronjobs liên quan docker/install.sh..."
grep -rl "docker\|install.sh\|redeploy" /etc/cron.d/ 2>/dev/null | xargs -r rm -f
sleep 2

# 7. Xóa systemd services/timers đáng ngờ
echo "[INFO] Tắt & xóa systemd services/timers đáng ngờ..."
for svc in \
  docker-apps.service \
  al2023-docker-setup.service \
  docker-boot-reset.service \
  docker-weekly-reset.service \
  auto-redeploy.service \
  iptables-fix.service; do
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
sleep 2

# 8. Reload systemd
systemctl daemon-reload
systemctl reset-failed

# 9. Xóa script .sh nghi ngờ
echo "[INFO] Xóa script .sh nghi ngờ..."
find /root -maxdepth 1 -type f -name "*.sh" -not -name "cleanup.sh" -exec rm -f {} \; || true
find /usr/local/bin -type f -name "*.sh" -exec rm -f {} \; || true
sleep 2

# 10. Hoàn tất
echo "=== [CLEANUP] Hoàn tất. Reboot sau 5 giây... ==="
sleep 5
reboot
