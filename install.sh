#!/bin/bash
set -e

echo "🚀 Bắt đầu cài đặt Docker Orchestrator ..."

# --- Cài đặt Docker nếu chưa có ---
if ! command -v docker &> /dev/null; then
  echo "[INFO] Cài Docker ..."
  yum update -y
  yum install -y docker
  systemctl enable docker
  systemctl start docker
fi

# --- Script chính start apps ---
cat >/usr/local/bin/docker-apps-start.sh <<'EOF'
#!/bin/bash
set -e
echo "[$(date +'%Y-%m-%d_%H:%M:%S')] 🚀 Docker apps auto-start running ..."

# Lấy IP động & tĩnh
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

# Hàm thêm rule iptables nếu thiếu
add_rule() {
    local NET=$1
    local IP=$2
    if ! iptables -t nat -C POSTROUTING -s $NET -j SNAT --to-source $IP 2>/dev/null; then
        echo "[FIX] Adding iptables rule for $NET -> $IP"
        iptables -t nat -I POSTROUTING -s $NET -j SNAT --to-source $IP
    else
        echo "[OK] iptables rule for $NET -> $IP exists"
    fi
}

# Fix NAT rules
add_rule "192.168.33.0/24" "$IP_ALLA"
add_rule "192.168.34.0/24" "$IP_ALLB"

# Chờ hệ thống ổn định
sleep 30

# --- Docker Networks ---
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# --- Containers ---
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

docker run -d --network my_network_1 --restart=always --cap-add NET_ADMIN --name ur1 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:2025.8.11-701332070@sha256:9feae0bfb50545b310bedae8937dc076f1d184182f0c47c14b5ba2244be3ed7a
docker run -d --network my_network_2 --restart=always --cap-add NET_ADMIN --name ur2 -e USER_AUTH="nguyenvinhcao123@gmail.com" -e PASSWORD="CAOcao123CAO@" ghcr.io/techroy23/docker-urnetwork:2025.8.11-701332070@sha256:9feae0bfb50545b310bedae8937dc076f1d184182f0c47c14b5ba2244be3ed7a

echo "[$(date +'%Y-%m-%d_%H:%M:%S')] ✅ All Docker apps started."
EOF
chmod +x /usr/local/bin/docker-apps-start.sh

# --- Service ---
cat >/etc/systemd/system/docker-apps.service <<'EOF'
[Unit]
Description=Docker Apps Auto Start
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-apps-start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- Timer reboot hàng tuần ---
cat >/etc/systemd/system/weekly-reboot.service <<'EOF'
[Unit]
Description=Weekly Reboot

[Service]
Type=oneshot
ExecStart=/usr/sbin/reboot
EOF

cat >/etc/systemd/system/weekly-reboot.timer <<'EOF'
[Unit]
Description=Weekly Reboot Timer

[Timer]
OnCalendar=Mon *-*-* 03:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# --- Timer refresh daily cho repocket + earnfm ---
cat >/etc/systemd/system/apps-daily-refresh.service <<'EOF'
[Unit]
Description=Daily refresh repocket + earnfm

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'docker rm -f repocket1 repocket2 earnfm1 earnfm2 || true; /usr/local/bin/docker-apps-start.sh'
EOF

cat >/etc/systemd/system/apps-daily-refresh.timer <<'EOF'
[Unit]
Description=Daily refresh repocket + earnfm

[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# --- Enable services ---
systemctl daemon-reexec
systemctl enable docker-apps.service
systemctl enable weekly-reboot.timer
systemctl enable apps-daily-refresh.timer
systemctl start docker-apps.service
systemctl start weekly-reboot.timer
systemctl start apps-daily-refresh.timer

echo "🎉 Cài đặt xong! Containers sẽ chạy sau reboot hoặc ngay bây giờ."
