#!/bin/bash
set -euo pipefail

echo "[INFO] === BẮT ĐẦU CLEANUP TOÀN BỘ (giữ volumes) ==="

# ==========================
# 1. Stop & remove ALL containers (bỏ restart policy trước)
# ==========================
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá containers..."
  for cid in $(docker ps -aq); do
    docker update --restart=no "$cid" >/dev/null 2>&1 || true
    docker rm -f "$cid" >/dev/null 2>&1 || true
  done
else
  echo "[INFO] Không có container nào."
fi
sleep 2

# ==========================
# 2. Remove ALL docker networks (trừ mặc định)
# ==========================
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  echo "[INFO] Xoá network: $net"
  docker network rm "$net" >/dev/null 2>&1 || true
done
sleep 2

# ==========================
# 3. Giữ lại volumes
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
sleep 2

# ==========================
# 5. Remove cron jobs
# ==========================
for cronfile in /etc/cron.d/docker_reset_every3days /etc/cron.d/docker_daily_restart /etc/cron.d/docker_weekly_reset; do
  [ -f "$cronfile" ] && sudo rm -f "$cronfile"
done
sleep 1

# ==========================
# 6. Remove systemd services
# ==========================
echo "[INFO] Xoá service auto-redeploy & iptables-fix..."
systemctl disable auto-redeploy.service --now >/dev/null 2>&1 || true
systemctl disable iptables-fix.service --now >/dev/null 2>&1 || true
rm -f /etc/systemd/system/auto-redeploy.service
rm -f /etc/systemd/system/iptables-fix.service
rm -f /usr/local/bin/fix_iptables.sh
systemctl daemon-reload
sleep 2

# ==========================
# 7. Remove scripts in /root
# ==========================
files_to_remove=(
  "/root/install.sh"
  "/root/fix-auto-redeployins.sh"
  "/root/auto-redeploy.sh"
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
  [ -f "$f" ] && rm -f "$f"
done
sleep 2

# ==========================
# 8. Done + reboot
# ==========================
echo "[INFO] === CLEANUP HOÀN TẤT (volumes giữ nguyên) ==="
echo "[INFO] Reboot hệ thống ngay..."
sleep 5
sudo reboot
