#!/bin/bash
set -e

echo "[INFO] 🚀 Bắt đầu cài đặt..."

# 1. Gỡ bỏ squid và httpd-tools nếu tồn tại
echo "[INFO] 🧹 Đang gỡ squid và httpd-tools..."
sudo yum remove -y squid httpd-tools || sudo apt remove -y squid httpd-tools || true

# 2. Cài docker nếu chưa có
if ! command -v docker &> /dev/null; then
  echo "[INFO] 🐳 Docker chưa có, đang cài đặt..."
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "[INFO] ✅ Docker đã cài xong → reboot hệ thống..."
  sudo reboot
  exit 0
fi

# 3. Tạo file docker-apps-start.sh
sudo tee /usr/local/bin/docker-apps-start.sh > /dev/null <<"EOF"
#!/bin/bash
set -e
echo "[INFO] 🕒 Đợi 30s cho hệ thống ổn định..."
sleep 30

# Tạo mạng docker
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# Khởi động docker service
systemctl start docker.service

# Lấy IP
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

# Thiết lập iptables
iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}

iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

echo "[INFO] 🐳 Đang khởi chạy containers..."

# Traffmonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

# Repocket
docker run --network my_network_1 --name repocket1 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest
docker run --network my_network_2 --name repocket2 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest

# Mysterium
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest 
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest 

# PacketSDK
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

# URnetwork (daily restart, linux/arm64, latest)
docker run -d --platform linux/arm64 --network my_network_1 --restart=always --cap-add NET_ADMIN --name ur1 \
  -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" \
  ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --platform linux/arm64 --network my_network_2 --restart=always --cap-add NET_ADMIN --name ur2 \
  -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" \
  ghcr.io/techroy23/docker-urnetwork:latest

echo "[INFO] ✅ All Docker apps started."
EOF

sudo chmod +x /usr/local/bin/docker-apps-start.sh

# 4. apps-daily-refresh.sh (reset repocket, earnfm mỗi 24h + restart ur)
sudo tee /usr/local/bin/apps-daily-refresh.sh > /dev/null <<"EOF"
#!/bin/bash
set -e
echo "[INFO] ♻️ Refreshing Repocket, EarnFM, UR..."

# Xoá containers cũ
docker rm -f repocket1 repocket2 earnfm1 earnfm2 ur1 ur2 || true

# Repocket
docker run --network my_network_1 --name repocket1 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest
docker run --network my_network_2 --name repocket2 -e RP_EMAIL=nguyenvinhson000@gmail.com -e RP_API_KEY=cad6dcce-d038-4727-969b-d996ed80d3ef -d --restart=always repocket/repocket:latest

# EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest 
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest 

# UR restart (latest, arm64)
docker run -d --platform linux/arm64 --network my_network_1 --restart=always --cap-add NET_ADMIN --name ur1 \
  -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" \
  ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --platform linux/arm64 --network my_network_2 --restart=always --cap-add NET_ADMIN --name ur2 \
  -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" \
  ghcr.io/techroy23/docker-urnetwork:latest

echo "[INFO] ✅ Refresh done."
EOF

sudo chmod +x /usr/local/bin/apps-daily-refresh.sh

# 5. Tạo systemd service & timer
sudo tee /etc/systemd/system/docker-apps.service > /dev/null <<"EOF"
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

sudo tee /etc/systemd/system/docker-apps-boot.timer > /dev/null <<"EOF"
[Unit]
Description=Run docker-apps.service 30s after boot

[Timer]
OnBootSec=30
Unit=docker-apps.service

[Install]
WantedBy=timers.target
EOF

sudo tee /etc/systemd/system/apps-daily-refresh.service > /dev/null <<"EOF"
[Unit]
Description=Daily refresh Repocket, EarnFM, UR
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apps-daily-refresh.sh
EOF

sudo tee /etc/systemd/system/apps-daily-refresh.timer > /dev/null <<"EOF"
[Unit]
Description=Run apps-daily-refresh.service once a day

[Timer]
OnCalendar=*-*-* 03:20:00
Unit=apps-daily-refresh.service

[Install]
WantedBy=timers.target
EOF

sudo tee /etc/systemd/system/weekly-reboot.service > /dev/null <<"EOF"
[Unit]
Description=Reboot the system weekly

[Service]
Type=oneshot
ExecStart=/sbin/shutdown -r now "Weekly auto reboot"
EOF

sudo tee /etc/systemd/system/weekly-reboot.timer > /dev/null <<"EOF"
[Unit]
Description=Weekly reboot

[Timer]
OnCalendar=Mon *-*-* 03:10:00
Unit=weekly-reboot.service

[Install]
WantedBy=timers.target
EOF

# Enable services
sudo systemctl daemon-reexec
sudo systemctl enable docker-apps.service docker-apps-boot.timer apps-daily-refresh.timer weekly-reboot.timer
sudo systemctl start docker-apps-boot.timer apps-daily-refresh.timer weekly-reboot.timer

echo "[INFO] ✅ Hoàn tất cài đặt!"
