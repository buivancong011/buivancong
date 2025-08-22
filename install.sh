#!/bin/bash
set -euo pipefail

LOCK_FILE="/tmp/setup.lock"
if [ -f "$LOCK_FILE" ]; then
  echo "[WARN] Script đã chạy hoặc reboot chưa xong, dừng lại."
  exit 0
fi
trap "rm -f $LOCK_FILE" EXIT
touch $LOCK_FILE

# ==== Bắt buộc gỡ squid & httpd-tools ====
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

# ==== Cài Cronie nếu chưa có ====
if ! command -v crond &> /dev/null; then
  echo "[INFO] Cronie chưa có -> Cài đặt..."
  timeout 120 sudo dnf install -y cronie
  sudo systemctl enable --now crond
  sleep 2
fi

# ==== Nếu có container đang chạy -> xóa hết container ====
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[WARN] Phát hiện container -> Xóa toàn bộ..."
  timeout 60 docker rm -f $(docker ps -aq) || true
fi
sleep 2

# ==== Xóa toàn bộ images cũ ====
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[WARN] Xóa toàn bộ images cũ..."
  docker rmi -f $(docker images -q) || true
fi
sleep 2

# ==== Xóa network cũ ====
echo "[INFO] Xóa toàn bộ network cũ..."
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  timeout 30 docker network rm "$net" || true
done
sleep 2

# ==== Tạo lại Docker networks ====
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true
sleep 2

# ==== Thiết lập iptables ban đầu ====
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
sleep 10   # ⬅️ Tăng delay để đảm bảo iptables áp dụng

if ! sudo iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} >/dev/null 2>&1; then
  echo "[ERROR] iptables SNAT lỗi. Stop Docker tránh rò mạng."
  sudo systemctl stop docker
  exit 1
fi

# ==== Cron reboot định kỳ (mỗi 3 ngày, 3h sáng) ====
set +u
CRON_FILE="/etc/cron.d/docker_reboot_every3days"
echo "0 3 */3 * * root /sbin/reboot" | sudo tee $CRON_FILE
sudo chmod 644 $CRON_FILE
sudo systemctl restart crond
set -u

# ==== Chạy các container gốc ====
set +e
echo "[INFO] Pull & Run containers..."

timeout 300 docker pull traffmonetizer/cli_v2:arm64v8
sleep 2
docker run -d --network my_network_1  --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM= || true
docker run -d --network my_network_2  --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM= || true

timeout 300 docker pull repocket/repocket:latest
sleep 2
docker run --network my_network_1 --name repocket1 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest || true
docker run --network my_network_2 --name repocket2 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest || true

timeout 300 docker pull mysteriumnetwork/myst:latest
sleep 2
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions || true
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions || true

timeout 300 docker pull earnfm/earnfm-client:latest
sleep 2
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest || true
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest || true

docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj || true
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj || true

docker run -d --network my_network_1 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest || true
docker run -d --network my_network_2 --restart=always --platform linux/arm64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest || true

# ==== Proxybase containers ====
echo "[INFO] Run Proxybase containers..."
PROXYBASE_ENV="/root/proxybase_device.env"
if [ ! -s "$PROXYBASE_ENV" ]; then
  DEVICE1=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
  DEVICE2=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
  {
    echo "DEVICE1=$DEVICE1"
    echo "DEVICE2=$DEVICE2"
  } > "$PROXYBASE_ENV"
else
  source "$PROXYBASE_ENV"
fi

docker run -d --network my_network_1 --name proxybase1 \
  -e USER_ID="L_0vehFMTO" \
  -e DEVICE_NAME="$DEVICE1" \
  --restart=always proxybase/proxybase:latest

docker run -d --network my_network_2 --name proxybase2 \
  -e USER_ID="L_0vehFMTO" \
  -e DEVICE_NAME="$DEVICE2" \
  --restart=always proxybase/proxybase:latest

set -e   # Bật lại strict mode

# ==== TÍCH HỢP AUTO-REDEPLOY SAU REBOOT ====
echo "[INFO] Cài auto-redeploy sau reboot..."

cat <<'EOF' > /root/auto-redeploy.sh
#!/bin/bash
set -euo pipefail

SCRIPT_PATH="/root/setup.sh"
LOG_FILE="/var/log/auto-redeploy.log"

echo "[$(date)] Auto redeploy starting..." | tee -a $LOG_FILE

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[$(date)] ERROR: $SCRIPT_PATH không tồn tại!" | tee -a $LOG_FILE
  exit 1
fi

/bin/bash "$SCRIPT_PATH" >> $LOG_FILE 2>&1
echo "[$(date)] Auto redeploy hoàn tất." | tee -a $LOG_FILE
EOF

chmod 755 /root/auto-redeploy.sh

cat <<'EOF' > /etc/systemd/system/auto-redeploy.service
[Unit]
Description=Auto run setup.sh after reboot
After=network.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash /root/auto-redeploy.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable auto-redeploy.service
echo "[INFO] Auto-redeploy đã được cấu hình thành công."
