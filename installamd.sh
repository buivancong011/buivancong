#!/bin/bash
set -euo pipefail

LOCK_FILE="/tmp/setup.lock"
if [ -f "$LOCK_FILE" ]; then
  echo "[WARN] Script đã chạy hoặc reboot chưa xong, dừng lại."
  exit 0
fi
trap "rm -f $LOCK_FILE" EXIT
touch $LOCK_FILE

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

# ==== Cài Cronie nếu chưa có ====
if ! command -v crond &> /dev/null; then
  echo "[INFO] Cronie chưa có -> Cài đặt..."
  timeout 120 sudo yum install -y cronie
  sudo systemctl enable --now crond
  sleep 2
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


# ==== Tạo lại Docker networks ====
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true
sleep 2

# ==== Thiết lập iptables ban đầu (interface enX0) ====
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute enX0 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic enX0 | awk '{gsub(/\/.*/,"",$4); print $4}')

fix_iptables() {
  echo "[INFO] Cấu hình lại iptables SNAT..."
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

# ==== Auto reboot mỗi 3 ngày bằng systemd timer ====
echo "[INFO] Thiết lập auto reboot mỗi 3 ngày..."

cat <<'EOF' | sudo tee /etc/systemd/system/auto-reboot.service
[Unit]
Description=Auto reboot every 3 days

[Service]
Type=oneshot
ExecStart=/sbin/reboot
EOF

cat <<'EOF' | sudo tee /etc/systemd/system/auto-reboot.timer
[Unit]
Description=Run auto reboot every 3 days

[Timer]
OnBootSec=1h
OnUnitActiveSec=3d
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now auto-reboot.timer

# ==== Auto run lại setup.sh sau reboot ====
echo "[INFO] Thiết lập auto run setup.sh sau reboot..."

cat <<EOF | sudo tee /etc/systemd/system/setup-autorun.service
[Unit]
Description=Run setup.sh after reboot
After=network.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /root/setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable setup-autorun.service
# ==== Chạy các container ====
echo "[INFO] Pull & Run containers..."
set +e
timeout 300 docker pull traffmonetizer/cli_v2:latest
sleep 2
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:latest start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:latest start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

timeout 300 docker pull repocket/repocket:latest
sleep 2
docker run --network my_network_1 --name repocket1 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest
docker run --network my_network_2 --name repocket2 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest

timeout 300 docker pull mysteriumnetwork/myst:latest
sleep 2
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

timeout 300 docker pull earnfm/earnfm-client:latest
sleep 2
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest

docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

docker run -d --network my_network_1 --restart=always --platform linux/amd64 --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --platform linux/amd64 --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

echo "[INFO] Run Proxybase containers..."
PROXYBASE_ENV="/root/proxybase_device.env"
if [ ! -f "$PROXYBASE_ENV" ]; then
  DEVICE1=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
  DEVICE2=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
  echo "DEVICE1=$DEVICE1" | sudo tee "$PROXYBASE_ENV"
  echo "DEVICE2=$DEVICE2" | sudo tee -a "$PROXYBASE_ENV"
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
set -e

# ==== AUTO-REDEPLOY SERVICE ====
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
