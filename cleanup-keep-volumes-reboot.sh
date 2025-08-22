#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu dọn dẹp toàn bộ (containers, images, services, cron, scripts), giữ volume Myst..."

# ==========================
# 1. Stop & remove containers
# ==========================
containers="tm1 tm2 repocket1 repocket2 myst1 myst2 earnfm1 earnfm2 packetsdk1 packetsdk2 ur1 ur2 proxybase1 proxybase2"
for c in $containers; do
  if docker ps -a --format '{{.Names}}' | grep -qw "$c"; then
    echo "[INFO] Xóa container: $c"
    docker rm -f "$c" >/dev/null 2>&1 || true
  fi
done

# ==========================
# 2. Remove docker networks
# ==========================
for net in my_network_1 my_network_2; do
  if docker network ls --format '{{.Name}}' | grep -qw "$net"; then
    echo "[INFO] Xóa network: $net"
    docker network rm "$net" >/dev/null 2>&1 || true
  fi
done

# ==========================
# 3. Giữ lại volumes Myst
# ==========================
echo "[INFO] Giữ lại volumes myst-data1 & myst-data2 (không xoá)."

# ==========================
# 4. Remove all Docker images
# ==========================
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Xóa toàn bộ Docker images..."
  docker rmi -f $(docker images -q) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có Docker image nào để xóa."
fi

# ==========================
# 5. Remove cron jobs
# ==========================
for cronfile in /etc/cron.d/docker_reset_every3days /etc/cron.d/docker_daily_restart /etc/cron.d/docker_weekly_reset; do
  if [ -f "$cronfile" ]; then
    echo "[INFO] Xóa cron: $cronfile"
    sudo rm -f "$cronfile"
  fi
done

# ==========================
# 6. Remove iptables-fix service
# ==========================
if systemctl list-unit-files | grep -q "^iptables-fix.service"; then
  echo "[INFO] Vô hiệu hóa & xóa service iptables-fix"
  sudo systemctl disable iptables-fix.service --now >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/iptables-fix.service
  sudo systemctl daemon-reload
fi

sudo rm -f /usr/local/bin/fix_iptables.sh

# ==========================
# 7. Remove auto-redeploy service & script
# ==========================
if systemctl list-unit-files | grep -q "^auto-redeploy.service"; then
  echo "[INFO] Vô hiệu hóa & xóa service auto-redeploy"
  sudo systemctl disable auto-redeploy.service --now >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/auto-redeploy.service
  sudo systemctl daemon-reload
fi

sudo rm -f /root/auto-redeploy.sh

# ==========================
# 8. Remove install/fix scripts & env files trong /root
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
    echo "[INFO] Xóa file: $f"
    sudo rm -f "$f"
  fi
done

# ==========================
# 9. Done + reboot
# ==========================
echo "[INFO] Dọn dẹp hoàn tất. Volume Myst vẫn còn nguyên."
echo "[INFO] Reboot hệ thống ngay..."
sleep 3
sudo reboot
