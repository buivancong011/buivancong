#!/bin/bash
set -e

echo "=== 🚀 Docker Orchestrator Installer (with Daily Refresh & Weekly Reboot) ==="

# =========================
# 1) Remove unwanted packages (safe if not present)
# =========================
echo "[INFO] 🔄 Removing squid & httpd-tools if present..."
yum remove -y squid httpd-tools || true
apt remove -y squid httpd-tools || true

# =========================
# 2) Install Docker if missing
# =========================
if ! command -v docker &> /dev/null; then
  echo "[INFO] 🐳 Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  echo "[INFO] 🔁 Rebooting system after Docker install..."
  reboot
  exit 0
else
  echo "[INFO] ✅ Docker already installed."
fi

# =========================
# 3) Create Docker networks (idempotent)
# =========================
echo "[INFO] 🌐 Creating Docker networks..."
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# =========================
# 4) Create startup script (ensures NAT; idempotent container start)
# =========================
echo "[INFO] 📝 Creating /usr/local/bin/docker-apps-start.sh ..."
cat >/usr/local/bin/docker-apps-start.sh <<'EOF'
#!/bin/bash
set -e

# ---------- Config ----------
IFACE="ens5"   # <-- đổi nếu máy bạn dùng interface khác
# ---------- Helpers ----------
exists() { docker ps -a --format '{{.Names}}' | grep -q "^$1$"; }
ensure_run() {
  # ensure_run <name> <docker run args...>
  local name="$1"; shift
  if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
    echo "→ $name exists. Restarting…"
    docker restart "$name" >/dev/null
  else
    echo "→ Creating $name"
    docker run -d "$@" || exit 1
  fi
}
add_nat_once() {
  local cidr="$1"; local ip="$2"
  if ! iptables -t nat -C POSTROUTING -s "$cidr" -j SNAT --to-source "$ip" 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$cidr" -j SNAT --to-source "$ip"
  fi
}

echo "[INFO] 🌐 Ensuring NAT rules..."
IP_ALLA=$(/sbin/ip -4 -o addr show dev "$IFACE" scope global noprefixroute | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
IP_ALLB=$(/sbin/ip -4 -o addr show dev "$IFACE" scope global dynamic       | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
if [ -z "$IP_ALLA" ]; then
  # nếu không có IP dynamic, dùng luôn IP_ALLA cho cả hai SNAT
  IP_ALLB="$IP_ALLA"
fi
[ -n "$IP_ALLA" ] || { echo "❌ Cannot detect IP on $IFACE"; exit 1; }

add_nat_once "192.168.33.0/24" "${IP_ALLA}"
add_nat_once "192.168.34.0/24" "${IP_ALLB}"
echo "[INFO] ✅ NAT ready."

echo "[INFO] 📦 Pulling images (best-effort)..."
docker pull traffmonetizer/cli_v2:arm64v8 || true
docker pull repocket/repocket:latest || true
docker pull mysteriumnetwork/myst:latest || true
docker pull earnfm/earnfm-client:latest || true
docker pull packetsdk/packetsdk || true
docker pull ghcr.io/techroy23/docker-urnetwork:latest || true

echo "[INFO] 🚀 Starting/Restarting containers (idempotent)..."

# Traffmonetizer (recreate behavior -> ensure_run is fine; name fixed)
ensure_run tm1 --network my_network_1 --restart always --name tm1 \
  traffmonetizer/cli_v2:arm64v8 start accept --token YOUR_TOKEN
ensure_run tm2 --network my_network_2 --restart always --name tm2 \
  traffmonetizer/cli_v2:arm64v8 start accept --token YOUR_TOKEN

# Repocket (CHỈ RESTART nếu có; nếu chưa có thì tạo mới)
ensure_run repocket1 --network my_network_1 --name repocket1 \
  -e RP_EMAIL=your@email \
  -e RP_API_KEY=your_key \
  --restart=always repocket/repocket:latest
ensure_run repocket2 --network my_network_2 --name repocket2 \
  -e RP_EMAIL=your@email \
  -e RP_API_KEY=your_key \
  --restart=always repocket/repocket:latest

# Mysterium (bind theo IP_ALLA/IP_ALLB)
ensure_run myst1 --network my_network_1 --cap-add NET_ADMIN \
  -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node \
  --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
ensure_run myst2 --network my_network_2 --cap-add NET_ADMIN \
  -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node \
  --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# EarnFM (CHỈ RESTART nếu có; nếu chưa có thì tạo mới)
# ⚠️ Lưu ý: EarnFM thường giới hạn 1 phiên/IP. Cân nhắc chỉ chạy earnfm1 trên máy này.
ensure_run earnfm1 --network my_network_1 --restart=always \
  -e EARNFM_TOKEN="YOUR_EARNFM_TOKEN" --name earnfm1 earnfm/earnfm-client:latest
# Nếu bạn có token/IP khác cho instance 2, giữ dòng dưới; nếu không, có thể comment lại.
ensure_run earnfm2 --network my_network_2 --restart=always \
  -e EARNFM_TOKEN="YOUR_EARNFM_TOKEN" --name earnfm2 earnfm/earnfm-client:latest

# PacketSDK
ensure_run packetsdk1 --network my_network_1 --restart unless-stopped \
  --name packetsdk1 packetsdk/packetsdk -appkey=YOUR_APPKEY
ensure_run packetsdk2 --network my_network_2 --restart unless-stopped \
  --name packetsdk2 packetsdk/packetsdk -appkey=YOUR_APPKEY

# UR Network (khuyên pin digest nếu có; ở đây dùng latest cho đơn giản)
ensure_run ur1 --network my_network_1 --restart=always --cap-add NET_ADMIN \
  --name ur1 -e USER_AUTH="youruser" -e PASSWORD="yourpass" \
  ghcr.io/techroy23/docker-urnetwork:latest
ensure_run ur2 --network my_network_2 --restart=always --cap-add NET_ADMIN \
  --name ur2 -e USER_AUTH="youruser" -e PASSWORD="yourpass" \
  ghcr.io/techroy23/docker-urnetwork:latest

echo "[INFO] ✅ All containers ensured."
EOF

chmod +x /usr/local/bin/docker-apps-start.sh

# =========================
# 5) Systemd service & boot timer
# =========================
echo "[INFO] ⚙️  Creating systemd unit & timer..."
cat >/etc/systemd/system/docker-apps.service <<'EOF'
[Unit]
Description=Docker Apps Auto Start
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-apps-start.sh
RemainAfterExit=yes
EOF

cat >/etc/systemd/system/docker-apps-boot.timer <<'EOF'
[Unit]
Description=Run docker-apps.service 30s after boot

[Timer]
OnBootSec=30
Unit=docker-apps.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

# =========================
# 6) Daily refresh (restart Repocket/EarnFM/UR + NAT check) & timer
# =========================
echo "[INFO] 📝 Creating /usr/local/bin/apps-daily-refresh.sh ..."
cat >/usr/local/bin/apps-daily-refresh.sh <<'EOF'
#!/bin/bash
set -e
ts(){ date +"[%Y-%m-%d_%H:%M:%S]"; }
echo "$(ts) Daily refresh: restart Repocket/EarnFM/UR (with NAT check)"

IFACE="ens5"  # đổi nếu cần
exists(){ docker ps -a --format '{{.Names}}' | grep -q "^$1$"; }
restart_if_exists(){
  local name="$1"
  if exists "$name"; then
    docker restart "$name" >/dev/null && echo "$(ts) Restarted $name"
  else
    echo "$(ts) Skip $name (not found)"
  fi
}

# Ensure NAT
IP_ALLA=$(/sbin/ip -4 -o addr show dev "$IFACE" scope global noprefixroute | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
IP_ALLB=$(/sbin/ip -4 -o addr show dev "$IFACE" scope global dynamic       | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
if [ -z "$IP_ALLA" ]; then IP_ALLB="$IP_ALLA"; fi
[ -n "$IP_ALLA" ] || { echo "$(ts) ❌ Cannot detect IPs on $IFACE"; exit 1; }

iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

# Restart targets (no remove)
for c in repocket1 repocket2 earnfm1 earnfm2 ur1 ur2; do
  restart_if_exists "$c"
done

echo "$(ts) Daily refresh done."
EOF
chmod +x /usr/local/bin/apps-daily-refresh.sh

cat >/etc/systemd/system/apps-daily-refresh.service <<'EOF'
[Unit]
Description=Apps Daily Refresh (restart repocket/earnfm/ur)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apps-daily-refresh.sh
EOF

cat >/etc/systemd/system/apps-daily-refresh.timer <<'EOF'
[Unit]
Description=Run Apps Daily Refresh at 03:20 UTC

[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true
Unit=apps-daily-refresh.service

[Install]
WantedBy=timers.target
EOF

# =========================
# 7) Weekly reboot service & timer
# =========================
cat >/etc/systemd/system/weekly-reboot.service <<'EOF'
[Unit]
Description=Weekly Reboot (every Monday 03:10 UTC)

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

cat >/etc/systemd/system/weekly-reboot.timer <<'EOF'
[Unit]
Description=Timer for Weekly Reboot

[Timer]
OnCalendar=Mon *-*-* 03:10:00
Persistent=true
Unit=weekly-reboot.service

[Install]
WantedBy=timers.target
EOF

# =========================
# 8) Enable timers (do NOT enable docker-apps.service directly to avoid double-run)
# =========================
systemctl daemon-reexec
systemctl daemon-reload

# Chỉ enable timer khởi động ứng dụng sau boot:
systemctl enable docker-apps-boot.timer
systemctl start  docker-apps-boot.timer

# Enable daily refresh + weekly reboot timers:
systemctl enable apps-daily-refresh.timer
systemctl enable weekly-reboot.timer
systemctl start  apps-daily-refresh.timer
systemctl start  weekly-reboot.timer

echo "=== ✅ Install completed."
echo "    • Check timers:    systemctl list-timers | egrep 'docker-apps|apps-daily|weekly-reboot'"
echo "    • Service logs:    journalctl -u docker-apps.service -n 50 --no-pager"
