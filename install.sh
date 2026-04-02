#!/bin/bash
set -e

# ==========================================
# 1. CẤU HÌNH TOKEN
# ==========================================
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="nguyenvinhcao123@gmail.com"
PASS_UR="CAOcao123CAO@"
EMAIL_BITPING="nguyenvinhcao123@gmail.com"
PASS_BITPING="nguyenvinhcao123@gmail.com"

# ==== CẤU HÌNH TỐI ƯU DOCKER TỔNG HỢP ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
# Giới hạn log 30MB + Mở khóa 1 triệu kết nối đồng thời cho mỗi app
DOCKER_OPTS="--log-opt max-size=10m --log-opt max-file=3 --ulimit nofile=1048576:1048576"

# ==== TỰ ĐỘNG CHỌN IMAGE THEO CPU ====
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  echo -e "\e[32m[INFO] Detected ARM64 CPU (AWS t4g/Graviton)\e[0m"
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  echo -e "\e[32m[INFO] Detected AMD64/x86 CPU\e[0m"
  IMG_TM="traffmonetizer/cli_v2:latest"
fi

IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"
IMG_BITPING="bitping/bitpingd:latest"

log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. KIỂM TRA MẠNG TỔNG
# ==========================================
log "Kiểm tra kết nối Internet sơ bộ..."
if ! curl -s --connect-timeout 5 https://1.1.1.1 > /dev/null; then
    err "VPS không có Internet! Dừng script ngay."
fi

# ==========================================
# 3. CHUẨN BỊ & DỌN DẸP HỆ THỐNG
# ==========================================
log "Dọn dẹp hệ thống..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

log "Tối ưu Kernel (BBR, Conntrack, TCP Reuse, Swappiness)..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10

net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65535
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

log "Cấu hình Swap 2GB (Tương thích XFS)..."
if [ ! -f /swapfile ]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null 2>&1
    sudo swapon /swapfile >/dev/null 2>&1
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

log "Dọn dẹp Container & Image rác..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1
docker image prune -af >/dev/null 2>&1

# ==========================================
# 4. LẤY IP PRIVATE TỰ ĐỘNG
# ==========================================
log "Đang tự động dò tìm Interface mạng chính..."
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)

if [ -z "$MAIN_IFACE" ]; then err "Không tìm thấy Interface mạng chính!"; fi
log "Đã tìm thấy Interface: $MAIN_IFACE"

IP_PRIVATE_A=$(/sbin/ip -4 -o addr show scope global noprefixroute $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)
IP_PRIVATE_B=$(/sbin/ip -4 -o addr show scope global dynamic $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)

if [ -z "$IP_PRIVATE_A" ] || [ -z "$IP_PRIVATE_B" ]; then 
    err "Không lấy đủ 2 IP Private trên $MAIN_IFACE! AWS chưa cấp IP thứ 2?"
fi
log "👉 IP Private detected: A=$IP_PRIVATE_A | B=$IP_PRIVATE_B"

# ==========================================
# 5. TẠO NETWORK & IPTABLES
# ==========================================
ensure_network() {
  local NET=$1; local SUB=$2
  if docker network inspect "$NET" >/dev/null 2>&1; then
      docker network rm "$NET" >/dev/null
  fi
  docker network create "$NET" --driver bridge --subnet "$SUB" >/dev/null
}

ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

log "Cấu hình IPTables SNAT..."
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B}

log "⏳ Đợi 5s cho iptables cập nhật..."
sleep 5

# ==========================================
# 6. CHECK IP PUBLIC THỰC TẾ
# ==========================================
get_public_ip() {
    local NET=$1
    docker run --rm --network "$NET" $DNS_OPTS curlimages/curl:latest -s --max-time 10 https://api.ipify.org || echo "FAIL"
}

log "🕵️ Đang kiểm tra IP Public thực tế..."
PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "👉 Kết quả Check:"
log "   Network 1 ($IP_PRIVATE_A) -> Public IP: [$PUB_IP_1]"
log "   Network 2 ($IP_PRIVATE_B) -> Public IP: [$PUB_IP_2]"

if [ "$PUB_IP_1" == "FAIL" ] || [ "$PUB_IP_2" == "FAIL" ]; then
    err "❌ LỖI: Không lấy được IP Public (Mất mạng hoặc Timeout)."
fi

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then
    err "❌ LỖI TRÙNG IP: Cả 2 mạng đều ra cùng 1 IP ($PUB_IP_1). Hãy check lại Elastic IP!"
else
    log "✅ THÀNH CÔNG: IP đã được tách biệt rõ ràng."
fi

# ==========================================
# 7. KHỞI CHẠY NODES MMO
# ==========================================
log "🚀 Mạng OK. Đang Pull images và khởi chạy nodes..."

for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO" "$IMG_BITPING"; do
  docker pull $img >/dev/null 2>&1 &
done
wait

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  docker run -d --network $NET --restart always --name tm$ID $DOCKER_OPTS $DNS_OPTS \
    $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  
  docker run -d --network $NET --cap-add NET_ADMIN $DOCKER_OPTS $DNS_OPTS \
    -p ${BIND_IP}:4449:4449 \
    --name myst$ID -v myst-data$ID:/var/lib/mysterium-node \
    --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null

  docker run -d --network $NET --restart always --cap-add NET_ADMIN $DOCKER_OPTS $DNS_OPTS \
    --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat \
    -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null

  docker run -d --network $NET --restart always $DOCKER_OPTS $DNS_OPTS \
    --name earnfm$ID \
    -e EARNFM_TOKEN="$TOKEN_EARNFM" $IMG_EARN >/dev/null

  docker run -d --network $NET --restart always $DOCKER_OPTS $DNS_OPTS \
    --name repocket$ID \
    -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

  docker run -d --network $NET --restart unless-stopped $DOCKER_OPTS $DNS_OPTS \
    --name bitping$ID \
    -v bitping_data$ID:/root/.bitpingd \
    -e BITPING_EMAIL="$EMAIL_BITPING" -e BITPING_PASSWORD="$PASS_BITPING" \
    $IMG_BITPING >/dev/null
}

run_node_group 1 "$IP_PRIVATE_A"
run_node_group 2 "$IP_PRIVATE_B"

echo "------------------------------------------------------"
log "==== HOÀN TẤT TRIỂN KHAI AWS MASTER ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
