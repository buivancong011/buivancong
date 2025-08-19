#!/bin/bash
set -e

echo "[INFO] 🚀 Bắt đầu setup hệ thống"

# ========== 1. XÓA SQUID + HTTPD-TOOLS ==========
echo "[INFO] 🗑️ Xóa squid + httpd-tools nếu có"
dnf remove -y squid httpd-tools || true

# ========== 2. CÀI ĐẶT DOCKER ==========
echo "[INFO] 🐳 Kiểm tra Docker"
if ! command -v docker &>/dev/null; then
    echo "[INFO] ➕ Cài đặt Docker"
    dnf install -y docker
    systemctl enable --now docker
else
    echo "[INFO] ✅ Docker đã có sẵn"
fi

# ========== 3. CÀI IPTABLES ==========
echo "[INFO] ⚙️ Cài iptables"
dnf install -y iptables-nft iptables-services iptables-utils
systemctl enable --now iptables

# ========== 4. TẠO NETWORKS ==========
echo "[INFO] 🌐 Tạo networks"
docker network create --subnet=192.168.33.0/24 my_network_1 || true
docker network create --subnet=192.168.34.0/24 my_network_2 || true

# ========== 5. THÊM RULE IPTABLES ==========
echo "[INFO] 🔥 Thêm rule iptables"
iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -j MASQUERADE
iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.34.0/24 -j MASQUERADE
service iptables save

# ========== 6. XÓA CONTAINERS CŨ ==========
echo "[INFO] 🗑️ Xóa containers cũ"
docker rm -f tm1 tm2 repocket1 repocket2 myst1 myst2 earnfm1 earnfm2 packetsdk1 packetsdk2 ur1 ur2 || true

# ========== 7. CHẠY CONTAINERS ==========
echo "[INFO] ✅ Bắt đầu khởi chạy containers"

# --- TraffMonetizer ---
docker pull traffmonetizer/cli_v2:arm64v8
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token "JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM="
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token "JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM="

# --- Repocket ---
docker pull repocket/repocket:latest
docker run -d --network my_network_1 --restart always --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest
docker run -d --network my_network_2 --restart always --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest

# --- Mysterium ---
docker pull mysteriumnetwork/myst:latest
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# --- EarnFM ---
docker pull earnfm/earnfm-client:latest
docker run -d --network my_network_1 --restart always --name earnfm1 -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart always --name earnfm2 -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" earnfm/earnfm-client:latest

# --- PacketSDK ---
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

# --- URNetwork ---
docker run -d --network my_network_1 --restart always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

# ========== 8. CRON JOB ==========
echo "[INFO] ⏰ Thiết lập cron jobs"

# Cài đặt cronie nếu chưa có
dnf install -y cronie
systemctl enable --now crond

# Xóa crontab cũ
crontab -r || true

# Thêm cron mới
cat <<EOF | crontab -
# Restart containers mỗi 24h (chia lệch giờ tránh quá tải)
0 2 * * * docker restart repocket1 repocket2
15 2 * * * docker restart earnfm1 earnfm2
30 2 * * * docker restart ur1 ur2

# Sau 7 ngày xóa toàn bộ containers + images + reboot
0 4 */7 * * docker rm -f \$(docker ps -aq) && docker rmi -f \$(docker images -q) && reboot
EOF

echo "[INFO] ✅ Hoàn tất cài đặt!"
