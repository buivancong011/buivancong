#!/bin/bash
set -e

# ==========================================
# 1. CẤU HÌNH TOKEN & TÀI KHOẢN
# ==========================================
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="nguyenvinhcao123@gmail.com"
PASS_UR="CAOcao123CAO@"

# ==== CẤU HÌNH BITPING ====
EMAIL_BITPING="nguyenvinhcao123@gmail.com"
PASS_BITPING="nguyenvinhcao123@gmail.com"

# ==== CẤU HÌNH TỐI ƯU DOCKER (LOG + LIMIT) ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
# Giới hạn log 30MB + Mở khóa 1 triệu kết nối đồng thời cho mỗi container
DOCKER_OPTS="--log-opt max-size=1m --log-opt max-file=1 --ulimit nofile=1048576:1048576"

# Hàm log
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. CHỌN IMAGE & PHÂN TÁCH KIẾN TRÚC (CPU)
# ==========================================
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  log "Detected ARM64 CPU (Graviton)."
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  log "Detected AMD64/x86 CPU (t2/t3a/t3)."
  IMG_TM="traffmonetizer/cli_v2:latest"
fi

IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"
IMG_BITPING="bitping/bitpingd:latest"

# ==========================================
# 3. CHUẨN BỊ & DỌN DẸP HỆ THỐNG
# ==========================================
log "Dọn dẹp hệ thống & Cài đặt bổ trợ..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true
sudo yum install -y -q jq coreutils iptables >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

# ==== CẤU HÌNH TỐI ƯU (SYSCTL & SWAP CHO AL2023) ====
log "Tối ưu Kernel (BBR, Conntrack 1 Triệu, Swappiness)..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10

net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=43200
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65535
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

log "Cấu hình Swap 2GB (Chống tràn RAM)..."
if [ ! -f /swapfile ]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null 2>&1
    sudo swapon /swapfile >/dev/null 2>&1
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
    log "Swap file đã tồn tại."
fi

log "Dọn dẹp container & network cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP THÔNG MINH (AWS SECONDARY IP)
# ==========================================
log "Đang dò tìm Interface mạng chính..."
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
[ -z "$MAIN_IFACE" ] && err "Không tìm thấy Interface mạng chính!"

IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then 
    err "LỖI: AWS chưa cấp đủ secondary IP trên $MAIN_IFACE!"
fi
log "👉 IP Bắt được: A=$IP_ALLA | B=$IP_ALLB"

# ==========================================
# 5. TẠO NETWORK & CẤU HÌNH IPTABLES
# ==========================================
ensure_network() {
  local NET=$1; local SUB=$2
  [ "$(docker network ls -qf name=^$NET$)" ] && docker network rm "$NET" >/dev/null
  docker network create "$NET" --driver bridge --subnet "$SUB" >/dev/null
}

ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

log "Cấu hình IPTables SNAT (Tách luồng IP)..."
sudo iptables -t nat -F POSTROUTING 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

log "⏳ Chờ 5s cập nhật mạng..."
sleep 5

# ==========================================
# 6. KIỂM TRA IP PUBLIC THỰC TẾ
# ==========================================
get_public_ip() {
    docker run --rm --network "$1" $DNS_OPTS curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Xác thực IP Public thực tế..."
PUB_IP_1=$(get_public_ip "my_network_1" || echo "FAIL")
PUB_IP_2=$(get_public_ip "my_network_2" || echo "FAIL")

log "   Check 1: Source $IP_ALLA -> Exit: [$PUB_IP_1]"
log "   Check 2: Source $IP_ALLB -> Exit: [$PUB_IP_2]"

if [ "$PUB_IP_1" == "FAIL" ] || [ "$PUB_IP_2" == "FAIL" ]; then 
    err "❌ LỖI: Không lấy được IP Public."
fi
if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then 
    err "❌ LỖI: Trùng IP Public. Hãy check lại Elastic IP trên AWS!"
fi

# ==========================================
# 7. KHỞI CHẠY NODES (FULL CẤU HÌNH TỐI ƯU)
# ==========================================
log "🚀 Đang Pull images (Song song)..."
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO" "$IMG_BITPING"; do
  docker pull $img >/dev/null 2>&1 &
done
wait

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  # Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $DOCKER_OPTS $DNS_OPTS \
    $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  
  # Mysterium
  docker run -d --network $NET --cap-add NET_ADMIN $DOCKER_OPTS $DNS_OPTS \
    -p ${BIND_IP}:4449:4449 \
    --name myst$ID -v myst-data$ID:/var/lib/mysterium-node \
    --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
  
  # UrNetwork
  docker run -d --network $NET --restart always --cap-add NET_ADMIN $DOCKER_OPTS $DNS_OPTS \
    --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat \
    -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
  
  # EarnFM
  docker run -d --network $NET --restart always $DOCKER_OPTS $DNS_OPTS \
    --name earnfm$ID \
    -e EARNFM_TOKEN="$TOKEN_EARNFM" $IMG_EARN >/dev/null
  
  # Repocket
  docker run -d --network $NET --restart always $DOCKER_OPTS $DNS_OPTS \
    --name repocket$ID \
    -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

  # Bitping
  docker run -d --network $NET --restart unless-stopped $DOCKER_OPTS $DNS_OPTS \
    --name bitping$ID \
    -v bitping_data$ID:/root/.bitpingd \
    -e BITPING_EMAIL="$EMAIL_BITPING" -e BITPING_PASSWORD="$PASS_BITPING" \
    $IMG_BITPING >/dev/null
}

log "🏗️ Đang khởi chạy 2 cụm Nodes..."
run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

log "==== DONE STARTING CONTAINERS - Vinh Cao ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
