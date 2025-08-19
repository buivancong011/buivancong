#!/bin/bash
set -euo pipefail

log() { echo "[INFO] $1"; }
err() { echo "[ERROR] $1" >&2; exit 1; }

log "🚀 Bắt đầu setup hệ thống"

# 1. Update hệ thống + remove squid, httpd-tools
dnf -y update
dnf -y remove squid httpd-tools || true

# 2. Cài Docker nếu chưa có
if ! command -v docker &>/dev/null; then
    log "🐳 Cài Docker"
    dnf -y install docker
    systemctl enable docker
    systemctl start docker
    log "🔁 Docker vừa được cài, reboot để hoàn tất"
    reboot
fi

# 3. Cài iptables + restart docker để sync chain
log "⚙️ Cài iptables"
dnf install -y iptables iptables-services iptables-utils
systemctl enable iptables
systemctl start iptables || err "❌ iptables không khởi động → DỪNG TOÀN BỘ!"
log "🔄 Restart Docker để đồng bộ lại iptables"
systemctl restart docker

# 4. Xóa toàn bộ container cũ (giữ image + volume)
log "🗑️ Xóa containers cũ"
docker ps -aq | xargs -r docker rm -f

# 5. Tạo networks
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# 6. Setup NAT iptables
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || \
iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}

iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || \
iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

service iptables save

# 7. Chạy containers
log "✅ Bắt đầu khởi chạy containers"

## TraffMonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

## Repocket
docker run -d --network my_network_1 --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" --restart=always repocket/repocket:latest
sleep 20
docker run -d --network my_network_2 --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" --restart=always repocket/repocket:latest

## Myst
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
sleep 20
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

## EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
sleep 20
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest

## PacketSDK
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
sleep 20
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

## UrNetwork
docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
sleep 20
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

# 8. Cron jobs
log "🕒 Thiết lập cron"

# Restart repocket, earnfm, ur mỗi 24h
(crontab -l 2>/dev/null; echo "0 3 * * * docker restart repocket1 repocket2 earnfm1 earnfm2 ur1 ur2") | crontab -

# Reset toàn bộ sau 7 ngày
(crontab -l 2>/dev/null; echo "0 5 */7 * * docker system prune -af --volumes && reboot") | crontab -

# 9. Systemd service để tự chạy sau reboot
log "⚙️ Tạo systemd service"
cat >/etc/systemd/system/install-onboot.service <<EOF
[Unit]
Description=Run install.sh at startup
After=network.target docker.service iptables.service
Wants=docker.service iptables.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/install.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable install-onboot.service

log "✅ Hoàn tất setup!"
