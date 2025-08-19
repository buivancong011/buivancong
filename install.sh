#!/bin/bash
# Amazon Linux 2023 - Auto Setup Script
# Author: bạn

set -euo pipefail

log() { echo -e "[INFO] $*"; }
err() { echo -e "[ERROR] $*" >&2; exit 1; }

log "🚀 Bắt đầu setup hệ thống"

# Update + cleanup
dnf update -y
dnf remove -y squid httpd-tools || true

# Install Docker + iptables nếu chưa có
if ! command -v docker &>/dev/null; then
  log "🐳 Cài Docker & iptables"
  dnf install -y docker iptables iptables-services
fi

systemctl enable docker
systemctl start docker
systemctl enable iptables
systemctl start iptables || err "❌ iptables không khởi động → DỪNG TOÀN BỘ!"

usermod -aG docker ec2-user || true

# Cleanup containers cũ (không xóa images/volumes)
if [ -n "$(docker ps -aq)" ]; then
  log "🗑️ Xóa containers cũ"
  docker rm -f $(docker ps -aq) || true
fi

# Docker networks
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# Lấy IP ens5
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

log "🔍 IP_ALLA=$IP_ALLA"
log "🔍 IP_ALLB=$IP_ALLB"

# iptables NAT rules
add_rule() {
  local subnet="$1"
  local ip="$2"
  if ! iptables -t nat -C POSTROUTING -s "$subnet" -j SNAT --to-source "$ip" 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$subnet" -j SNAT --to-source "$ip" \
      || err "❌ Không thể thêm iptables rule cho $subnet"
    log "✅ Rule NAT $subnet → $ip đã thêm"
  else
    log "ℹ️ Rule NAT cho $subnet đã tồn tại"
  fi
}
add_rule "192.168.33.0/24" "$IP_ALLA"
add_rule "192.168.34.0/24" "$IP_ALLB"
service iptables save || err "❌ Không thể lưu iptables"

log "✅ iptables OK → bắt đầu khởi chạy containers"

# === Containers ===
# Đợt 1: TraffMonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token YOUR_TRAFF_TOKEN
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token YOUR_TRAFF_TOKEN
sleep 10

# Đợt 2: Repocket
docker run -d --network my_network_1 --restart=always --name repocket1 -e RP_EMAIL="your@mail.com" -e RP_API_KEY="YOUR_KEY" repocket/repocket:latest
docker run -d --network my_network_2 --restart=always --name repocket2 -e RP_EMAIL="your@mail.com" -e RP_API_KEY="YOUR_KEY" repocket/repocket:latest
sleep 15

# Đợt 3: Mysterium
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
sleep 20

# Đợt 4: EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="YOUR_EARNFM_TOKEN" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="YOUR_EARNFM_TOKEN" --name earnfm2 earnfm/earnfm-client:latest
sleep 15

# Đợt 5: PacketSDK + UrNetwork
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=YOUR_APPKEY
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=YOUR_APPKEY
sleep 10
docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="your@mail.com" -e PASSWORD="your_pass" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="your@mail.com" -e PASSWORD="your_pass" ghcr.io/techroy23/docker-urnetwork:latest

log "✅ Containers đã chạy"

# =============================
# Cron Jobs
# =============================

log "🕒 Tạo cron jobs cho restart & reset"

CRON_FILE="/etc/cron.d/container-maintenance"
cat <<EOF > $CRON_FILE
# Restart Repocket hàng ngày 02:00
0 2 * * * root /usr/bin/docker restart repocket1 repocket2

# Restart EarnFM hàng ngày 02:30
30 2 * * * root /usr/bin/docker restart earnfm1 earnfm2

# Restart UrNetwork hàng ngày 03:00
0 3 * * * root /usr/bin/docker restart ur1 ur2

# Reset toàn bộ hệ thống mỗi tuần (xóa container + images + reboot)
0 4 * * 0 root /usr/bin/docker rm -f \$(/usr/bin/docker ps -aq) && /usr/bin/docker rmi -f \$(/usr/bin/docker images -q) && /usr/sbin/reboot
EOF

chmod 644 $CRON_FILE
log "✅ Cron jobs đã cấu hình"
