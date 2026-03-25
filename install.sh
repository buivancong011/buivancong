#!/bin/bash
set -e

# ==========================================
# 1. CẤU HÌNH TOKEN (GIỮ NGUYÊN)
# ==========================================
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="nguyenvinhcao123@gmail.com"
PASS_UR="CAOcao123CAO@"

# ==== CẤU HÌNH TỐI ƯU (CHỈ DNS) ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"

# ==== TỰ ĐỘNG CHỌN IMAGE THEO CPU ====
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  echo "[INFO] Detected ARM64 CPU"
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  echo "[INFO] Detected AMD64/x86 CPU"
  IMG_TM="traffmonetizer/cli_v2:latest"
fi
IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"

# ==== HÀM LOG ====
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==== 1. CHUẨN BỊ ====
log "Dọn dẹp hệ thống..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

# ==== 1.5. CẤU HÌNH TỐI ƯU (SYSCTL & SWAP) ====
log "Cấu hình bộ nhớ đệm mạng (4MB), BBR và Swappiness (15)..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

log "Cấu hình Swap 2GB..."
if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
    log "Swap file đã tồn tại, bỏ qua bước tạo mới."
fi

# ==== 2. LẤY IP PRIVATE (QUAN TRỌNG CHO IPTABLES) ====
IP_PRIVATE_A=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_PRIVATE_B=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

if [ -z "$IP_PRIVATE_A" ] || [ -z "$IP_PRIVATE_B" ]; then err "Không lấy được IP Private trên ens5!"; fi
log "IP Private detected: A=$IP_PRIVATE_A | B=$IP_PRIVATE_B"

# ==== 3. DỌN DẸP DOCKER ====
# Chỉ xóa container đang chạy, KHÔNG xóa volume (giữ nguyên dữ liệu)
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==== 4. TẠO NETWORK ====
ensure_network() {
  local NET=$1; local SUB=$2
  if docker network inspect "$NET" >/dev/null 2>&1; then
      CUR_SUB=$(docker network inspect "$NET" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
      if [ "$CUR_SUB" != "$SUB" ]; then docker network rm "$NET"; else return 0; fi
  fi
  docker network create "$NET" --driver bridge --subnet "$SUB" >/dev/null
}

ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

# ==== 5. CẤU HÌNH IPTABLES ====
log "Cấu hình IPTables SNAT..."
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B}

log "⏳ Đợi 5s cho iptables cập nhật..."
sleep 5

# ==== 6. CHECK IP PUBLIC THỰC TẾ ====
get_public_ip() {
    local NET=$1
    docker run --rm --network "$NET" $DNS_OPTS curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Đang kiểm tra IP Public thực tế..."

PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "👉 Kết quả Check:"
log "   Network 1 -> Public IP: [$PUB_IP_1]"
log "   Network 2 -> Public IP: [$PUB_IP_2]"

if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then
    err "❌ LỖI: Không lấy được IP Public."
fi

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then
    err "❌ LỖI TRÙNG IP: Cả 2 mạng đều ra cùng 1 IP ($PUB_IP_1)."
else
    log "✅ THÀNH CÔNG: IP khác nhau."
fi

# ==== 7. CHẠY NODES (GIỮ NGUYÊN LOG) ====
log "🚀 Mạng OK. Đang khởi chạy nodes..."

for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
wait

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  # Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $DNS_OPTS \
    $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  
  # Mysterium
  docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS \
    -p ${BIND_IP}:4449:4449 \
    --name myst$ID -v myst-data$ID:/var/lib/mysterium-node \
    --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null

  # UrNetwork
  docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS \
    --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat \
    -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null

  # EarnFM
  docker run -d --network $NET --restart always $DNS_OPTS \
    -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$ID $IMG_EARN >/dev/null

  # Repocket
  docker run -d --network $NET --restart always $DNS_OPTS \
    --name repocket$ID \
    -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null
}

run_node_group 1 "$IP_PRIVATE_A"
run_node_group 2 "$IP_PRIVATE_B"

log "==== DONE ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
