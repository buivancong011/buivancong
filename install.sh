#!/bin/bash
set -e

# ==== CẤU HÌNH TOKEN ====
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="nguyenvinhcao123@gmail.com"
PASS_UR="CAOcao123CAO@"

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

# ==== 2. LẤY IP PRIVATE (QUAN TRỌNG CHO IPTABLES) ====
# Ta lấy IP Private gắn trên card mạng để làm mốc cho iptables SNAT
IP_PRIVATE_A=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_PRIVATE_B=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

if [ -z "$IP_PRIVATE_A" ] || [ -z "$IP_PRIVATE_B" ]; then err "Không lấy được IP Private trên ens5!"; fi
log "IP Private detected (dùng cho routing): A=$IP_PRIVATE_A | B=$IP_PRIVATE_B"

# ==== 3. DỌN DẸP DOCKER ====
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

# ==== 5. CẤU HÌNH IPTABLES (SNAT THEO IP PRIVATE) ====
log "Cấu hình IPTables SNAT..."
# Reset rules cũ
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B} 2>/dev/null || true
# Apply rules mới (Map dải mạng docker -> IP Private card mạng)
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B}

log "⏳ Đợi 5s cho iptables cập nhật..."
sleep 5

# ==== 6. CHECK IP PUBLIC THỰC TẾ (LOGIC MỚI) ====
get_public_ip() {
    local NET=$1
    # Dùng api.ipify.org hoặc ifconfig.me để lấy IP Public
    docker run --rm --network "$NET" curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Đang kiểm tra IP Public thực tế..."

PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "👉 Kết quả Check:"
log "   Network 1 (Private: $IP_PRIVATE_A) -> Ra ngoài bằng Public IP: [$PUB_IP_1]"
log "   Network 2 (Private: $IP_PRIVATE_B) -> Ra ngoài bằng Public IP: [$PUB_IP_2]"

# KIỂM TRA ĐIỀU KIỆN
if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then
    err "❌ LỖI: Không lấy được IP Public (Mất mạng hoặc lỗi Docker)."
fi

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then
    err "❌ LỖI TRÙNG IP: Cả 2 mạng đều đang ra cùng 1 IP Public ($PUB_IP_1). Cấu hình Fail!"
else
    log "✅ THÀNH CÔNG: Hai mạng đã nhận diện 2 IP Public KHÁC NHAU."
fi

# ==== 7. CHẠY NODES (NẾU CHECK THÀNH CÔNG) ====
log "🚀 Mạng OK. Đang khởi chạy nodes..."

# Pull images background
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
wait

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  # Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  
  # Mysterium (Bind vào IP Private để port forward đúng)
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

# Lưu ý: Mysterium cần bind port vào IP Private để forward traffic
run_node_group 1 "$IP_PRIVATE_A"
run_node_group 2 "$IP_PRIVATE_B"

log "==== DONE ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
