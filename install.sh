#!/bin/bash
set -e

# ==== CẤU HÌNH TOKEN ====
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="testphuong123@gmail.com"
PASS_UR="CAOcao123456789"

# ==== CẤU HÌNH IMAGE (TỰ ĐỘNG DETECT CPU) ====
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

# ==== HÀM TIỆN ÍCH ====
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==== 1. CHUẨN BỊ ====
log "Dọn dẹp Squid/Httpd..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

# ==== 2. LẤY IP ====
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then err "Không lấy được IP!"; fi
log "IP Detected: A=$IP_ALLA | B=$IP_ALLB"

# ==== 3. CLEANUP DOCKER ====
log "Dọn dẹp Container/Network cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==== 4. TẠO & CHECK NETWORK ====
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

# ==== 5. IPTABLES ====
log "Cấu hình IPTables..."
# Xóa rule cũ
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
# Thêm rule mới
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

log "⏳ Đợi 10s để mạng ổn định..."
sleep 10

# ==== 6. CHECK IP PUBLIC THỰC TẾ (QUAN TRỌNG) ====
verify_docker_outgoing_ip() {
  local NET=$1; local EXP_IP=$2
  log "🕵️ Check IP Public của mạng $NET..."
  # Dùng curlimages/curl cho nhẹ và đa nền tảng
  ACTUAL_IP=$(docker run --rm --network "$NET" curlimages/curl:latest -s --max-time 10 https://ifconfig.me/ip)
  
  if [ "$ACTUAL_IP" == "$EXP_IP" ]; then
      log "✅ OK: $NET -> $ACTUAL_IP"
  else
      err "❌ SAI IP: $NET ra ngoài bằng '$ACTUAL_IP' (Kỳ vọng: $EXP_IP). DỪNG!"
  fi
}

verify_docker_outgoing_ip "my_network_1" "$IP_ALLA"
verify_docker_outgoing_ip "my_network_2" "$IP_ALLB"

# ==== 7. RUN NODES ====
log "Mạng OK. Đang chạy nodes..."

# Pull images song song
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
wait

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  # Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  
  # Mysterium (Cần volume riêng)
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

log "==== DONE ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
