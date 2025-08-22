#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu dọn dẹp toàn bộ (xoá tất cả container, network, images, scripts; giữ volumes)..."

# ==========================
# 1. Stop & remove ALL containers
# ==========================
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá toàn bộ containers..."
  docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có container nào."
fi
sleep 3

# ==========================
# 2. Remove ALL docker networks (trừ mặc định)
# ==========================
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  echo "[INFO] Xoá network: $net"
  docker network rm "$net" >/dev/null 2>&1 || true
  sleep 1
done
sleep 2

# ==========================
# 3. Giữ lại tất cả volumes
# ==========================
echo "[INFO] Giữ lại toàn bộ Docker volumes (không xoá)."
sleep 2

# ==========================
# 4. Remove ALL Docker images
# ==========================
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá toàn bộ Docker images..."
  docker rmi -f $(docker images -q) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có image nào."
fi
sleep 3

# ==========================
# 5. Remove cron jobs
# ==========================
for cronfile in /etc/cron.d/docker_reset_every3days /etc/cron.d/docker_daily_restart /etc/cron.d/docker_weekly_reset; do
  if [ -f "$cronfile" ]; then
    echo "[INFO] Xoá cron: $cronfile"
    sudo rm -f "$cronfile"
    sleep 1
  fi
done
sleep 2

# ==========================
# 6. Remove iptables-fix service
# ==========================
if systemctl list-unit-files | grep -q "^iptables-fix.service"; then
  echo "[INFO] Vô hiệu hoá & xoá service iptables-fix"
  sudo systemctl disable iptables-fix.service --now >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/iptables-fix.service
  sudo systemctl daemon-reload
  sleep 2
fi

sudo rm -f /usr/local/bin/fix_iptables.sh
sleep 1

# ==========================
# 7. Remove auto-redeploy service & script
# ==========================
if systemctl list-unit-files | grep -q "^auto-redeploy.service"; then
  echo "[INFO] Vô hiệu hoá & xoá service auto-redeploy"
  sudo systemctl disable auto-redeploy.service --now >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/auto-redeploy.service
  sudo systemctl daemon-reload
  sleep 2
fi

sudo rm -f /root/auto-redeploy.sh
sleep 1

# ==========================
# 8. Remove all install/fix scripts & rác trong /root
# ==========================
files_to_remove=(
  "/root/install.sh"
  "/root/fix-auto-redeployins.sh"
  "/root/proxybase_device.env"
  "/root/amazon-linux-2023.sh"
  "/root/check_status.sh"
  "/root/docker-boot-reset.sh"
  "/root/docker-weekly-reset.sh"
  "/root/restart-earnfm.sh"
  "/root/restart-repocket.sh"
  "/root/restart-ur.sh"
  "/root/squid-conf-ip.sh"
  "/root/WAN_IFACE=ens5"
)

for f in "${files_to_remove[@]}"; do
  if [ -f "$f" ]; then
    echo "[INFO] Xoá file: $f"
    sudo rm -f "$f"
    sleep 1
  fi
done
sleep 2

# ==========================
# 9. Done + reboot
# ==========================
echo "[INFO] Dọn dẹp hoàn tất. Toàn bộ containers, networks, images, cron, service, scripts đã xoá; volumes vẫn giữ nguyên."
echo "[INFO] Reboot hệ thống ngay..."
sleep 5
sudo reboot
