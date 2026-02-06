#!/bin/bash
set -euo pipefail



# ==== Gỡ squid & httpd-tools nếu có ====
timeout 60 sudo yum remove -y squid httpd-tools || true
sleep 2

# ==== Cài Docker nếu chưa có ====
if ! command -v docker &> /dev/null; then
  echo "[INFO] Docker chưa có -> Cài đặt..."
  timeout 300 sudo yum update -y || true
  timeout 300 sudo yum install -y docker
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "[INFO] Docker cài xong, reboot lần đầu..."
  sleep 5
  sudo reboot
fi


# ==== Xóa toàn bộ containers ====
if [ "$(docker ps -q | wc -l)" -gt 0 ]; then
  echo "[WARN] Xóa containers..."
  timeout 60 docker rm -f $(docker ps -aq) || true
fi
sleep 2

# ==== Xóa toàn bộ images ====
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[WARN] Xóa images..."
  docker rmi -f $(docker images -q) || true
fi
sleep 2

# ==== Xóa toàn bộ docker networks cũ (trừ mặc định) ====
echo "[INFO] Xóa networks cũ..."
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  timeout 30 docker network rm "$net" || true
done
sleep 2

# ==== Tạo lại docker networks ====
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true
sleep 2

# ==== Lấy IP public & private (DigitalOcean) ====
IP_ALLA=$(ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^10\.')
IP_ALLB=$(ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '^10\.')

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then
  echo "[ERROR] Không lấy được IP eth0"
  exit 1
fi

# ==== Thiết lập iptables ban đầu ====
fix_iptables() {
  echo "[INFO] Thiết lập iptables SNAT..."
  sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
  sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
  sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
  sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
}
fix_iptables
sleep 10

if ! sudo iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} >/dev/null 2>&1; then
  echo "[ERROR] iptables SNAT lỗi. Stop Docker tránh rò mạng."
  sudo systemctl stop docker
  exit 1
fi

# ==== Chạy các container ====
echo "[INFO] Pull & Run containers..."
set +e

# traffmonetizer
timeout 300 docker pull traffmonetizer/cli_v2:latest
sleep 2
docker run -d --network my_network_1 --restart always --dns 8.8.8.8 --dns 1.1.1.1 --name tm1 traffmonetizer/cli_v2:latest start accept --token /PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno=
docker run -d --network my_network_2 --restart always --dns 8.8.8.8 --dns 1.1.1.1 --name tm2 traffmonetizer/cli_v2:latest start accept --token /PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno=

# repocket
timeout 300 docker pull repocket/repocket:latest
sleep 2
docker run -d --network my_network_1 --restart=always --dns 8.8.8.8 --dns 1.1.1.1 -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest 
docker run -d --network my_network_2 --restart=always --dns 8.8.8.8 --dns 1.1.1.1 -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest 

# myst
timeout 300 docker pull mysteriumnetwork/myst:latest
sleep 2
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# earnfm
timeout 300 docker pull earnfm/earnfm-client:latest
sleep 2
docker run -d --network my_network_1 --restart=always --dns 8.8.8.8 --dns 1.1.1.1 -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest 
docker run -d --network my_network_2 --restart=always --dns 8.8.8.8 --dns 1.1.1.1 -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest 
# urnetwork
docker run -d --network my_network_1  --name urnetwork1 --restart always  --cap-add NET_ADMIN --dns 8.8.8.8 --dns 1.1.1.1 -v ur_data1:/var/lib/vnstat -e USER_AUTH='buivancong012@gmail.com' -e PASSWORD='buivancong012' techroy23/docker-urnetwork:latest
docker run -d --network my_network_2  --name urnetwork2 --restart always  --cap-add NET_ADMIN --dns 8.8.8.8 --dns 1.1.1.1 -v ur_data2:/var/lib/vnstat -e USER_AUTH='buivancong012@gmail.com' -e PASSWORD='buivancong012' techroy23/docker-urnetwork:latest

docker run -d --network my_network_1 --name antgain1 --restart always --dns 8.8.8.8 --dns 1.1.1.1 -e ANTGAIN_API_KEY=ud0F9rj2KgAXWgJ20Dw6sogFOjJvytLyVSGtQUrfo4QJq3LAAvdh8XF5jUERcIeU pinors/antgain-cli:latest
docker run -d --network my_network_2 --name antgain2 --restart always --dns 8.8.8.8 --dns 1.1.1.1 -e ANTGAIN_API_KEY=ud0F9rj2KgAXWgJ20Dw6sogFOjJvytLyVSGtQUrfo4QJq3LAAvdh8XF5jUERcIeU pinors/antgain-cli:latest

set -e
