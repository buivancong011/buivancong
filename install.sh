#!/bin/bash
set -euo pipefail

LOCK_FILE="/tmp/setup.lock"
if [ -f "$LOCK_FILE" ]; then
  echo "[WARN] Script đã chạy hoặc reboot chưa xong, dừng lại."
  exit 0
fi
trap "rm -f $LOCK_FILE" EXIT
touch $LOCK_FILE

# ==== Cài Docker nếu chưa có ====
if ! command -v docker &> /dev/null; then
  echo "[INFO] Docker chưa có -> Cài đặt..."
  sudo yum remove -y squid httpd-tools || true
  sudo yum update -y
  sudo yum install -y docker
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "[INFO] Docker cài xong, reboot lần đầu..."
  sudo reboot
fi

# ==== Nếu có container đang chạy -> xóa hết container + network ====
if [ "$(docker ps -q | wc -l)" -gt 0 ]; then
  echo "[WARN] Phát hiện container đang chạy -> Xóa toàn bộ..."
  docker rm -f $(docker ps -aq) || true
fi

echo "[INFO] Xóa toàn bộ network cũ..."
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  docker network rm "$net" || true
done

# ==== Tạo lại Docker networks ====
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24

# ==== Thiết lập iptables với auto-fix ====
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

fix_iptables() {
  echo "[INFO] Cấu hình lại iptables SNAT..."
  sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
  sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
  sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
  sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
}

fix_iptables

if ! sudo iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} >/dev/null 2>&1; then
  echo "[ERROR] iptables SNAT lỗi. Stop Docker tránh rò mạng."
  sudo systemctl stop docker
  exit 1
fi

# ==== Reset hàng tuần (không xóa volume) ====
WEEKLY_RESET_FLAG="/var/lib/docker_weekly_reset"
NOW=$(date +%s)
if [ -f "$WEEKLY_RESET_FLAG" ]; then
  LAST_RESET=$(cat "$WEEKLY_RESET_FLAG")
else
  LAST_RESET=0
fi

if [ $((NOW - LAST_RESET)) -ge 604800 ] || [ "${1:-}" == "force-reset" ]; then
  echo "[INFO] Reset tuần -> Xóa containers + images (giữ volume)"
  sudo docker rm -f $(docker ps -aq) || true
  sudo docker rmi -f $(docker images -q) || true
  date +%s | sudo tee "$WEEKLY_RESET_FLAG"
  echo "[INFO] Reboot để làm mới..."
  sudo reboot
fi

# ==== Chạy các container ====
echo "[INFO] Pull & Run containers..."
docker pull traffmonetizer/cli_v2:arm64v8
docker run -d --network my_network_1  --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2  --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

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

docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

# ==== Cron restart hàng ngày (3h sáng) ====
CRON_FILE="/etc/cron.d/docker_daily_restart"
echo "0 3 * * * root docker restart repocket1 repocket2 earnfm1 earnfm2 ur1 ur2" | sudo tee $CRON_FILE
sudo chmod 644 $CRON_FILE
sudo systemctl restart crond
