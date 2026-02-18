#!/bin/bash
set -e

# ==========================================
# 1. CẤU HÌNH TOKEN & TÀI KHOẢN
# ==========================================
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="buivancong012@gmail.com"
PASS_UR="buivancong012"

# ==========================================
# 2. CHỌN IMAGE & PHÂN TÁCH KIẾN TRÚC (CPU)
# ==========================================
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  echo -e "\e[32m[INFO] Detected ARM64 CPU (Graviton)\e[0m"
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  echo -e "\e[32m[INFO] Detected AMD64/x86 CPU\e[0m"
  IMG_TM="traffmonetizer/cli_v2:latest"
fi

IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"

# Hàm log
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 3. CHUẨN BỊ & DỌN DẸP
# ==========================================
log "Dọn dẹp hệ thống..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

log "Dọn dẹp container cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP THEO CƠ CHẾ ENX0 (THEO YÊU CẦU)
# ==========================================
log "Đang bắt IP trên interface enX0..."

# IP_ALLA: Lấy IP có thuộc tính noprefixroute
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute enX0 | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)

# IP_ALLB: Lấy IP có thuộc tính dynamic
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic enX0 | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then 
    err "Không lấy được IP trên enX0! Hãy kiểm tra lệnh: ip addr show dev enX0"
fi

log "👉 IP Bắt được: A (noprefix)=$IP_ALLA | B (dynamic)=$IP_ALLB"

# ==========================================
# 5. TẠO NETWORK & CẤU HÌNH IPTABLES
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
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

log "⏳ Chờ 5s cập nhật mạng..."
sleep 5

# ==========================================
# 6. KIỂM TRA IP PUBLIC THỰC TẾ
# ==========================================
get_public_ip() {
    local NET=$1
    docker run --rm --network "$NET" curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Đang xác thực IP Public thực tế..."
PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "   Check 1: Source $IP_ALLA -> Exit: [$PUB_IP_1]"
log "   Check 2: Source $IP_ALLB -> Exit: [$PUB_IP_2]"

if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then err "Lỗi kết nối ra ngoài internet!"; fi
if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then err "LỖI: Trùng IP Public. Kiểm tra lại routing!"; fi

# ==========================================
# 7. KHỞI CHẠY NODES (KHÔNG DNS)
# ==========================================
log "🚀 Đang Pull images (Song song)..."
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
wait

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  # Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  # Mysterium
  docker run -d --network $NET --cap-add NET_ADMIN -p ${BIND_IP}:4449:4449 \
    --name myst$ID -v myst-data$ID:/var/lib/mysterium-node \
    --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
  # UrNetwork
  docker run -d --network $NET --restart always --cap-add NET_ADMIN \
    --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat \
    -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
  # EarnFM
  docker run -d --network $NET --restart always -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$ID $IMG_EARN >/dev/null
  # Repocket
  docker run -d --network $NET --restart always --name repocket$ID \
    -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null
}

run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

log "==== DONE - Vinh Cao ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
