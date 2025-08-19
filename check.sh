#!/bin/bash
set -e

echo "[INFO] 🚀 Bắt đầu setup hệ thống"

# 1. Xóa gói không cần thiết
echo "[INFO] 🗑️ Gỡ squid và httpd-tools nếu có"
dnf remove -y squid httpd-tools || true

# 2. Cài Docker nếu chưa có
if ! command -v docker &> /dev/null; then
    echo "[INFO] ⚙️ Cài Docker"
    dnf install -y docker
    systemctl enable --now docker
    echo "[INFO] 🔄 Reboot sau khi cài Docker lần đầu"
    reboot
    exit 0
else
    echo "[INFO] ✅ Docker đã có sẵn"
fi

# 3. Cài iptables
echo "[INFO] ⚙️ Cài iptables"
dnf install -y iptables-nft iptables-services iptables-utils
systemctl enable --now iptables

# 4. Restart Docker để đồng bộ iptables
echo "[INFO] 🔄 Restart Docker để đồng bộ lại iptables"
systemctl restart docker

# 5. Xóa containers cũ (không xóa images, volumes)
echo "[INFO] 🗑️ Xóa containers cũ"
docker rm -f $(docker ps -aq) 2>/dev/null || true

# 6. Tạo networks (nếu chưa tồn tại)
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 2>/dev/null || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 2>/dev/null || true

# 7. Áp dụng iptables với IP động
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

if ! iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} &>/dev/null; then
    iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
    echo "[INFO] ✅ Rule NAT cho 192.168.33.0/24 đã thêm"
else
    echo "[INFO] ℹ️ Rule NAT cho 192.168.33.0/24 đã tồn tại"
fi

if ! iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} &>/dev/null; then
    iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
    echo "[INFO] ✅ Rule NAT cho 192.168.34.0/24 đã thêm"
else
    echo "[INFO] ℹ️ Rule NAT cho 192.168.34.0/24 đã tồn tại"
fi

service iptables save

# 8. Chạy containers
echo "[INFO] ✅ Bắt đầu khởi chạy containers"

## Traffmonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

## Repocket
docker run -d --network my_network_1 --restart always --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest
docker run -d --network my_network_2 --restart always --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest

## Myst
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

## EarnFM
docker run -d --network my_network_1 --restart always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest

## Packetsdk
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

## UR Network
docker run -d --network my_network_1 --restart always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

# 9. Cài cronjob tự động
echo "[INFO] ⚙️ Cài đặt cronie (cron service)"
if ! command -v crontab &> /dev/null; then
    dnf install -y cronie
    systemctl enable --now crond
fi

echo "[INFO] 📌 Cập nhật cronjob"
(crontab -l 2>/dev/null; echo "0 */24 * * * /usr/bin/docker restart repocket1 repocket2 earnfm1 earnfm2 ur1 ur2") | crontab -
(crontab -l 2>/dev/null; echo "0 0 */7 * * /usr/bin/docker rm -f \$(docker ps -aq) && /usr/bin/docker rmi -f \$(docker images -q) && /usr/sbin/reboot") | crontab -

# 10. Tạo systemd service để chạy lại sau reboot
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
