#!/bin/bash
set -e

echo "[INFO] 🚀 Bắt đầu setup hệ thống"

# ================== Cài đặt cơ bản ==================
echo "[INFO] 🗑️ Xóa squid + httpd-tools nếu có"
dnf remove -y squid httpd-tools || true

echo "[INFO] 🐳 Kiểm tra Docker"
if ! command -v docker &>/dev/null; then
    dnf update -y
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    echo "[INFO] ✅ Docker đã được cài đặt và khởi động lại"
else
    echo "[INFO] ✅ Docker đã có sẵn"
    systemctl restart docker
fi

echo "[INFO] ⚙️ Cài iptables"
dnf install -y iptables iptables-services iptables-utils
systemctl enable iptables
systemctl start iptables

# ================== Mạng và NAT ==================
echo "[INFO] 🌐 Tạo networks"
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 2>/dev/null || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 2>/dev/null || true

IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

echo "[INFO] 🔥 Thêm rule iptables"
iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
service iptables save

# ================== Xóa containers cũ ==================
echo "[INFO] 🗑️ Xóa containers cũ"
docker rm -f tm1 tm2 repocket1 repocket2 myst1 myst2 earnfm1 earnfm2 packetsdk1 packetsdk2 ur1 ur2 2>/dev/null || true

# ================== Chạy containers ==================
echo "[INFO] ✅ Bắt đầu khởi chạy containers"

# TraffMonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token "JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM="
sleep 5
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token "JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM="
sleep 10

# Repocket
docker run -d --network my_network_1 --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" --restart=always repocket/repocket:latest
sleep 10
docker run -d --network my_network_2 --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" --restart=always repocket/repocket:latest
sleep 10

# Mysterium
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
sleep 10
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
sleep 10

# EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
sleep 10
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest
sleep 10

# PacketSDK
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
sleep 5
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
sleep 10

# UrNetwork
docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
sleep 10
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

# ================== Cron jobs ==================

# Restart repocket, earnfm, ur sau 24h
echo "0 0 * * * root docker restart repocket1 repocket2 earnfm1 earnfm2 ur1 ur2 >/dev/null 2>&1" > /etc/cron.d/restart24h

# Xoá toàn bộ container + images sau 7 ngày
echo "0 3 */7 * * root docker rm -f \$(docker ps -aq) && docker rmi -f \$(docker images -q) && reboot" > /etc/cron.d/cleanup7d

# ================== Service tự chạy sau reboot ==================
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

echo "[INFO] 🎉 Hoàn tất setup!"
