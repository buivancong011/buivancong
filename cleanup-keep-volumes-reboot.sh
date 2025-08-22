#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu dọn dẹp mọi thứ từ install.sh + fix-auto-redeployins.sh (giữ volume Myst)..."

# ==========================
# 1. Stop & remove containers
# ==========================
containers="tm1 tm2 repocket1 repocket2 myst1 myst2 earnfm1 earnfm2 packetsdk1 packetsdk2 ur1 ur2 proxybase1 proxybase2"
for c in $containers; do
  if docker ps -a --format '{{.Names}}' | grep -qw "$c"; then
    echo "[INFO] Xóa container: $c"
    docker rm -f "$c" || true
  fi
done

# ==========================
# 2. Remove docker networks
# ==========================
for net in my_network_1 my_network_2; do
  if docker network ls --format '{{.Name}}' | grep -qw "$net"; then
    echo "[INFO] Xóa network: $net"
    docker network rm "$net" || true
  fi
done

# ==========================
# 3. Giữ lại volumes Myst
# ==========================
echo "[INFO] Giữ lại volumes myst-data1 & myst-data2 (không xoá)."

# ==========================
# 4. Remove cron jobs
# ==========================
if [ -f /etc/cron.d/docker_reset_every3days ]; then
  echo "[INFO] Xóa cron: /etc/cron.d/docker_reset_every3days"
  sudo rm -f /etc/cron.d/docker_reset_every3days
fi

# ==========================
# 5. Remove iptables-fix service
# ==========================
if systemctl list-unit-files | grep -q "^iptables-fix.service"; then
  echo "[INFO] Vô hiệu hóa & xóa service iptables-fix"
  sudo systemctl disable iptables-fix.service --now || true
  sudo rm -f /etc/systemd/system/iptables-fix.service
  sudo systemctl daemon-reload
fi

if [ -f /usr/local/bin/fix_iptables.sh ]; then
  echo "[INFO] Xóa script fix_iptables.sh"
  sudo rm -f /usr/local/bin/fix_iptables.sh
fi

# ==========================
# 6. Remove auto-redeploy service & script
# ==========================
if systemctl list-unit-files | grep -q "^auto-redeploy.service"; then
  echo "[INFO] Vô hiệu hóa & xóa service auto-redeploy"
  sudo systemctl disable auto-redeploy.service --now || true
  sudo rm -f /etc/systemd/system/auto-redeploy.service
  sudo systemctl daemon-reload
fi

sudo rm -f /root/auto-redeploy.sh

# ==========================
# 7. Remove install/fix scripts & env files
# ==========================
sudo rm -f /root/install.sh
sudo rm -f /root/fix-auto-redeployins.sh
sudo rm -f /root/proxybase_device.env

# ==========================
# 8. Done + reboot
# ==========================
echo "[INFO] Đã dọn dẹp toàn bộ container, network, cron, service, script liên quan (volume Myst giữ nguyên)."
echo "[INFO] Reboot hệ thống ngay..."
sleep 3
sudo reboot
