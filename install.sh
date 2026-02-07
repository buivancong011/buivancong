#!/bin/bash
set -e

# ==========================================
# CẤU HÌNH TOKEN & TÀI KHOẢN
# ==========================================
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="nguyenvinhcao123@gmail.com"
PASS_UR="CAOcao123CAO@"

# ==========================================
# TỰ ĐỘNG CHỌN IMAGE THEO CPU (ARM/AMD)
# ==========================================
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  echo "[INFO] Detected ARM64 CPU (Graviton)"
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  echo "[INFO] Detected AMD64/x86 CPU (Intel/AMD)"
  IMG_TM="traffmonetizer/cli_v2:latest"
fi
IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"

# HÀM LOG MÀU MÈ
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 1. CHUẨN BỊ HỆ THỐNG
# ==========================================
log "Dọn dẹp Squid/Httpd..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

# ==========================================
# 2. LẤY IP PRIVATE (DÙNG CHO IPTABLES)
# ==========================================
# Lấy IP Private trên card mạng ens5 để map luồng dữ liệu
IP_PRIVATE_A=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_PRIVATE_B=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

if [ -z "$IP_PRIVATE_A" ] || [ -z "$IP_PRIVATE_B" ]; then err "Không lấy được IP Private trên ens5!"; fi
log "IP Private detected: A=$IP_PRIVATE_A | B=$IP_PRIVATE_B"

# ==========================================
# 3. DỌN DẸP DOCKER CŨ
# ==========================================
log "Dọn dẹp Container/Network cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. TẠO NETWORK (CÓ THÊM DNS)
# ==========================================
ensure_network() {
  local NET=$1; local SUB=$2
  
  # Kiểm tra nếu network đã tồn tại
  if docker network inspect "$NET" >/dev/null 2>&1; then
      CUR_SUB=$(docker network inspect "$NET" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
      # Nếu sai Subnet thì xóa đi
      if [ "$CUR_SUB" != "$SUB" ]; then 
          warn "Network $NET sai subnet ($CUR_SUB). Xóa tạo lại..."
          docker network rm "$NET"
      else 
          # Nếu đúng subnet thì return luôn (hoặc xóa đi tạo lại để update DNS nếu muốn chắc chắn)
          return 0
      fi
  fi
  
  # 👉 THÊM DNS TẠI ĐÂY 👈
  log "Tạo network $NET với DNS Google & Cloudflare..."
  docker network create "$NET" --driver bridge --subnet "$SUB" --dns 8.8.8.8 --dns 1.1.1.1 >/dev/null
}

ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

# ==========================================
# 5. CẤU HÌNH IPTABLES (SNAT)
# ==========================================
log "Cấu hình IPTables SNAT..."
# Xóa rule cũ
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B} 2>/dev/null || true
# Thêm rule mới
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_PRIVATE_A}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_PRIVATE_B}

log "⏳ Đợi 5 giây cho rule mạng áp dụng..."
sleep 5

# ==========================================
# 6. KIỂM TRA IP PUBLIC THỰC TẾ (QUAN TRỌNG)
# ==========================================
get_public_ip() {
    local NET=$1
    # Dùng curl trong container để xem thế giới bên ngoài thấy IP nào
    docker run --rm --network "$NET" curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Đang kiểm tra IP Public thực tế của từng mạng..."

PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "👉 Kết quả Check:"
log "   Network 1 (Private: $IP_PRIVATE_A) -> Ra ngoài bằng Public IP: [$PUB_IP_1]"
log "   Network 2 (Private: $IP_PRIVATE_B) -> Ra ngoài bằng Public IP: [$PUB_IP_2]"

# KIỂM TRA ĐIỀU KIỆN AN TOÀN
if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then
    err "❌ LỖI: Không lấy được IP Public (Mất mạng hoặc lỗi Docker)."
fi

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then
    err "❌ LỖI NGHIÊM TRỌNG: TRÙNG IP! Cả 2 mạng đều ra cùng 1 IP ($PUB_IP_1). DỪNG NGAY!"
else
    log "✅ THÀNH CÔNG: Hai mạng đã nhận diện 2 IP Public KHÁC NHAU."
fi

# ==========================================
# 7. KHỞI CHẠY NODES
# ==========================================
log "🚀 Mạng OK. Đang khởi chạy nodes..."

# Pull images song song cho nhanh
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

# Chạy nhóm 1 và nhóm 2
run_node_group 1 "$IP_PRIVATE_A"
run_node_group 2 "$IP_PRIVATE_B"

log "==== HOÀN TẤT - KIỂM TRA TRẠNG THÁI ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
