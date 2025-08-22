#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu xoá tất cả cấu hình & container (giữ volumes)..."

# ==== Stop & remove all containers ====
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Đang xoá toàn bộ container..."
  docker rm -f $(docker ps -aq) || true
fi

# ==== Remove all docker images ====
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Đang xoá toàn bộ images..."
  docker rmi -f $(docker images -q) || true
fi

# ==== KHÔNG xoá docker volumes (giữ lại dữ liệu) ====
echo "[INFO] Giữ nguyên volumes, không xoá."

# ==== Remove custom docker networks ====
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  echo "[INFO] Xoá network: $net"
  docker network rm "$net" || true
done

# ==== Remove cron jobs ====
echo "[INFO] Xoá cron jobs..."
sudo rm -f /etc/cron.d/docker_daily_restart
sudo rm -f /etc/cron.d/docker_weekly_reset
sudo rm -f /etc/cron.d/docker_reset_every3days

# ==== Remove iptables-fix script & service ====
echo "[INFO] Xoá iptables-fix..."
sudo rm -f /usr/local/bin/fix_iptables.sh
sudo systemctl disable iptables-fix.service --now || true
sudo rm -f /etc/systemd/system/iptables-fix.service
sudo systemctl daemon-reload

# ==== Remove lock file ====
sudo rm -f /tmp/setup.lock

# ==== Thông báo hoàn tất và reboot ====
echo "[INFO] Dọn dẹp hoàn tất (volumes vẫn còn nguyên)!"
echo "[INFO] Reboot hệ thống ngay để áp dụng thay đổi..."
sleep 3
sudo reboot
