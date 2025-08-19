#!/bin/bash
set -euo pipefail

log() { echo -e "[INFO] $*"; }
err() { echo -e "[ERROR] $*" >&2; exit 1; }

log "🚀 Bắt đầu setup hệ thống"

# ===============================
# 1. Update + Cleanup
# ===============================
dnf update -y
dnf remove -y squid httpd-tools || true

# ===============================
# 2. Install Docker + iptables
# ===============================
DOCKER_INSTALLED=0
if ! command -v docker &>/dev/null; then
  log "🐳 Docker chưa có → tiến hành cài đặt"
  dnf install -y docker iptables iptables-services
  DOCKER_INSTALLED=1
else
  log "✅ Docker đã có sẵn"
  dnf install -y iptables iptables-services
fi

systemctl enable docker
systemctl start docker
systemctl enable iptables

if [ $DOCKER_INSTALLED -eq 1 ]; then
  log "🔄 Docker vừa được cài → reboot hệ thống để hoàn tất"
  reboot
  exit 0
fi

systemctl start iptables || err "❌ iptables không khởi động → DỪNG TOÀN BỘ!"
usermod -aG docker ec2-user || true

# ===============================
# 3. Cleanup containers cũ
# ===============================
if [ -n "$(docker ps -aq)" ]; then
  log "🗑️ Xóa containers cũ"
  docker rm -f $(docker ps -aq) || true
fi

# ===============================
# 4. Docker networks
# ===============================
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# ===============================
# 5. Lấy IP ens5
# ===============================
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

# ===============================
# 6. iptables NAT rules
# ===============================
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

# ===============================
# 7. Containers (batch + delay)
# ===============================

# Batch 1: TraffMonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
sleep 10

# Batch 2: Repocket
docker run -d --network my_network_1 --restart=always --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest
docker run -d --network my_network_2 --restart=always --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest
sleep 15

# Batch 3: Mysterium
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
sleep 20

# Batch 4: EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest
sleep 15

# Batch 5: PacketSDK + UrNetwork
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
sleep 10
docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

log "✅ Containers đã chạy thành công"

# ===============================
# 8. Cron Jobs
# ===============================
CRON_FILE="/etc/cron.d/container-maintenance"
cat <<EOF > $CRON_FILE
0 2 * * * root /usr/bin/docker restart repocket1 repocket2
30 2 * * * root /usr/bin/docker restart earnfm1 earnfm2
0 3 * * * root /usr/bin/docker restart ur1 ur2
0 4 * * 0 root /usr/bin/docker rm -f \$(/usr/bin/docker ps -aq) && /usr/bin/docker rmi -f \$(/usr/bin/docker images -q) && /usr/sbin/reboot
EOF
chmod 644 $CRON_FILE

# ===============================
# 9. Systemd service auto-run after reboot
# ===============================
SERVICE_FILE="/etc/systemd/system/install-onboot.service"
cat <<EOF > $SERVICE_FILE
[Unit]
Description=Run install.sh on boot
After=network.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/install.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable install-onboot.service

log "✅ install.sh sẽ tự chạy lại sau mỗi reboot"
