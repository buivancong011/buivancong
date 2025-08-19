#!/bin/bash
set -e
echo "=== Bắt đầu cài đặt Docker Orchestrator ==="

# 1. Gỡ các gói không mong muốn
yum remove -y squid httpd-tools || true
apt remove -y squid httpd-tools || true

# 2. Cài Docker nếu chưa có
if ! command -v docker &> /dev/null; then
  echo "=== Cài đặt Docker ==="
  yum install -y docker || apt install -y docker.io
  systemctl enable docker
  systemctl start docker
  echo "=== Reboot sau khi cài Docker mới ==="
  reboot
else
  echo "=== ✅ Docker đã có sẵn ==="
fi

# 3. Tạo Docker networks
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# 4. Tạo script khởi động apps
cat << 'EOF' > /usr/local/bin/docker-apps-start.sh
#!/bin/bash
set -e

echo "=== Xóa container và images cũ ==="
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker rmi -f $(docker images -q) 2>/dev/null || true

# Lấy IP máy chủ
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

echo "=== Thiết lập iptables NAT ==="
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} || { echo "❌ Lỗi iptables NAT cho my_network_1"; exit 1; }
iptables -t nat -A POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} || { echo "❌ Lỗi iptables NAT cho my_network_2"; exit 1; }

echo "✅ iptables thành công → Bắt đầu khởi chạy containers"

# --- Các container bạn dùng ---
docker pull traffmonetizer/cli_v2:arm64v8
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

docker pull repocket/repocket:latest
docker run --network my_network_1 --name repocket1 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest
docker run --network my_network_2 --name repocket2 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest

docker pull mysteriumnetwork/myst:latest
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

docker pull earnfm/earnfm-client:latest
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest 
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest 

docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

docker run -d --network my_network_1 --restart=always --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:2025.8.11-701332070@sha256:9feae0bfb50545b310bedae8937dc076f1d184182f0c47c14b5ba2244be3ed7a
docker run -d --network my_network_2 --restart=always --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:2025.8.11-701332070@sha256:9feae0bfb50545b310bedae8937dc076f1d184182f0c47c14b5ba2244be3ed7a
EOF

chmod +x /usr/local/bin/docker-apps-start.sh

# 5. Tạo service systemd cho docker-apps-start.sh
cat << 'EOF' > /etc/systemd/system/docker-apps.service
[Unit]
Description=Docker Apps Auto Start
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-apps-start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 6. (Giữ nguyên phần daily refresh + weekly reboot như bản gốc)
# ... (phần này bạn đã có, không đổi)

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable docker-apps.service
systemctl start docker-apps.service

echo "=== ✅ Hoàn tất cài đặt Docker Orchestrator (có kiểm tra iptables) ==="
