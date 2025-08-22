#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu xoá SẠCH Docker (containers, networks, images, services, scripts). Giữ volumes."

# 1. Xoá toàn bộ containers
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá toàn bộ containers..."
  docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có container nào."
fi
sleep 2

# 2. Xoá toàn bộ networks (trừ mặc định)
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  echo "[INFO] Xoá network: $net"
  docker network rm "$net" >/dev/null 2>&1 || true
  sleep 1
done
sleep 2

# 3. Giữ lại toàn bộ volumes
echo "[INFO] Giữ lại toàn bộ Docker volumes (không xoá)."
sleep 2

# 4. Xoá toàn bộ images
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá toàn bộ Docker images..."
  docker rmi -f $(docker images -q) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có image nào."
fi
sleep 2

# 5. Xoá cron jobs
for cronfile in /etc/cron.d/docker_reset_every3days /etc/cron.d/docker_daily_restart /etc/cron.d/docker_weekly_reset; do
  [ -f "$cronfile" ] && sudo rm -f "$cronfile"
done

# 6. Xoá services
sudo systemctl disable iptables-fix.service --now >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/iptables-fix.service
sudo rm -f /usr/local/bin/fix_iptables.sh
sudo systemctl disable auto-redeploy.service --now >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/auto-redeploy.service
sudo systemctl daemon-reload

# 7. Xoá scripts trong /root
rm -f /root/{install.sh,fix-auto-redeployins.sh,auto-redeploy.sh,proxybase_device.env,amazon-linux-2023.sh,check_status.sh,docker-boot-reset.sh,docker-weekly-reset.sh,restart-earnfm.sh,restart-repocket.sh,restart-ur.sh,squid-conf-ip.sh,WAN_IFACE=ens5} || true

echo "[INFO] Dọn dẹp hoàn tất (volumes vẫn giữ nguyên)."
sleep 5
sudo reboot
