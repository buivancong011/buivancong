#!/bin/bash
set -e

echo "=== 🚀 Bắt đầu cài đặt Docker Orchestrator ==="

# =========================
# 1. Xoá squid & httpd-tools
# =========================
echo "=== 🔥 Xoá squid và httpd-tools nếu tồn tại ==="
yum remove -y squid httpd-tools || true
apt remove -y squid httpd-tools || true

# =========================
# 2. Cài Docker nếu chưa có
# =========================
if ! command -v docker &> /dev/null; then
  echo "=== 🐳 Cài đặt Docker ==="
  yum install -y docker
  systemctl enable docker
  systemctl start docker
  echo "=== 🔄 Docker mới được cài, reboot để hoàn tất ==="
  reboot
  exit 0
else
  echo "=== ✅ Docker đã có sẵn ==="
fi

# =========================
# 3. Tạo docker networks
# =========================
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# =========================
# 4. Thiết lập iptables NAT+SNAT
# =========================
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic | awk '{gsub(/\/.*/,"",$4); print $4; exit}')

if ! iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
fi
if ! iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
fi

# =========================
# 5. Script khởi động sau reboot
# =========================
cat << 'EOF' > /usr/local/bin/docker-apps-start.sh
#!/bin/bash
set -e
echo "[\$(date)] 🚀 Starting all Docker apps..."
sleep 30

# Check iptables trước khi chạy
for NET in "192.168.33.0/24" "192.168.34.0/24"; do
    if ! iptables -t nat -S POSTROUTING | grep -q $NET; then
        echo "[ERROR] ❌ Missing SNAT rule for $NET. Stop containers."
        exit 1
    fi
done

# Pull images
docker pull traffmonetizer/cli_v2:arm64v8
docker pull repocket/repocket:latest
docker pull mysteriumnetwork/myst:latest
docker pull earnfm/earnfm-client:latest
docker pull packetsdk/packetsdk:latest
docker pull ghcr.io/techroy23/docker-urnetwork:latest

# Run containers
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM=

docker run -d --network my_network_1 --restart always --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest
docker run -d --network my_network_2 --restart always --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest

docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest

docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

docker run -d --network my_network_1 --restart=always --cap-add NET_ADMIN --platform linux/arm64 --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --cap-add NET_ADMIN --platform linux/arm64 --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:latest

EOF
chmod +x /usr/local/bin/docker-apps-start.sh

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

# =========================
# 6. Daily refresh (repocket + earnfm reinstall, ur restart)
# =========================
cat << 'EOF' > /usr/local/bin/apps-daily-refresh.sh
#!/bin/bash
set -e
echo "[\$(date)] 🔄 Daily refresh started..."

# Check iptables
for NET in "192.168.33.0/24" "192.168.34.0/24"; do
    if ! iptables -t nat -S POSTROUTING | grep -q $NET; then
        echo "[ERROR] ❌ Missing SNAT rule for $NET. Abort daily refresh."
        exit 1
    fi
done

# Refresh repocket & earnfm (remove container, keep image)
docker rm -f repocket1 repocket2 earnfm1 earnfm2 || true
docker run -d --network my_network_1 --restart always --name repocket1 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest
docker run -d --network my_network_2 --restart always --name repocket2 -e RP_EMAIL="nguyenvinhson000@gmail.com" -e RP_API_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef" repocket/repocket:latest

docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb" --name earnfm2 earnfm/earnfm-client:latest

# Restart ur1 ur2 (chỉ restart, không rm -f)
docker restart ur1 ur2 || true

echo "[\$(date)] ✅ Daily refresh done."
EOF
chmod +x /usr/local/bin/apps-daily-refresh.sh

cat << 'EOF' > /etc/systemd/system/apps-daily-refresh.service
[Unit]
Description=Daily refresh Repocket/EarnFM & restart UR
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apps-daily-refresh.sh
EOF

cat << 'EOF' > /etc/systemd/system/apps-daily-refresh.timer
[Unit]
Description=Run apps-daily-refresh once per day

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# =========================
# 7. Weekly reboot
# =========================
cat << 'EOF' > /etc/systemd/system/weekly-reboot.service
[Unit]
Description=Weekly Reboot

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

cat << 'EOF' > /etc/systemd/system/weekly-reboot.timer
[Unit]
Description=Weekly Reboot Timer

[Timer]
OnCalendar=Mon *-*-* 03:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# =========================
# 8. Enable tất cả service
# =========================
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable docker-apps.service
systemctl enable apps-daily-refresh.timer
systemctl enable weekly-reboot.timer
systemctl start docker-apps.service
systemctl start apps-daily-refresh.timer
systemctl start weekly-reboot.timer

echo "=== ✅ Hoàn tất cài đặt Docker Orchestrator ==="
