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
TOKEN_PROXYRACK_API="KK3M5OBY1TDBZ97KMJBBYKIV4PE9DIKUXIERYWVA"

# ==== CẤU HÌNH TỐI ƯU & MARKERS ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
MARKER_FILE="/root/.proxyrack_registered_vinh"   # Cờ máy cũ (V1)
MARKER_V2="/root/.proxyrack_v2_mac_vinh"        # Cờ máy mới (V2)

# Mảng lưu thông tin để gọi API Proxyrack
declare -a PR_UUIDS
declare -a PR_NAMES

# Hàm log
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. CHỌN IMAGE & PHÂN TÁCH KIẾN TRÚC (CPU)
# ==========================================
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  echo -e "\e[32m[INFO] Detected ARM64 CPU. Proxyrack sẽ bị bỏ qua.\e[0m"
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  echo -e "\e[32m[INFO] Detected AMD64/x86 CPU (t2/t3a). Proxyrack đã sẵn sàng.\e[0m"
  IMG_TM="traffmonetizer/cli_v2:latest"
fi

IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"
IMG_PR="proxyrack/pop:latest"

# ==========================================
# 3. CHUẨN BỊ & DỌN DẸP HỆ THỐNG
# ==========================================
log "Dọn dẹp hệ thống..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true
sudo yum install -y -q jq coreutils >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

# ==== CẤU HÌNH TỐI ƯU (SYSCTL & SWAP CHO AL2023) ====
log "Cấu hình bộ nhớ đệm mạng, BBR và Swappiness..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

log "Cấu hình Swap 2GB (Tương thích XFS/AL2023)..."
if [ ! -f /swapfile ]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
    log "Swap file đã tồn tại, bỏ qua bước tạo mới."
fi

log "Dọn dẹp container & network cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP THÔNG MINH (TỰ ĐỘNG TÌM INTERFACE)
# ==========================================
log "Đang tự động dò tìm Interface mạng chính..."
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)

if [ -z "$MAIN_IFACE" ]; then err "Không tìm thấy Interface mạng chính!"; fi
log "Đã tìm thấy Interface: $MAIN_IFACE"

IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then 
    err "Không lấy đủ 2 IP trên $MAIN_IFACE! AWS chưa cấp đủ secondary IP?"
fi

log "👉 IP Bắt được: A=$IP_ALLA | B=$IP_ALLB"

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
    docker run --rm --network "$NET" $DNS_OPTS curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Đang xác thực IP Public thực tế..."
PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "   Check 1: Source $IP_ALLA -> Exit: [$PUB_IP_1]"
log "   Check 2: Source $IP_ALLB -> Exit: [$PUB_IP_2]"

if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then 
    err "❌ LỖI: Không lấy được IP Public (Mất mạng hoặc Timeout)."
fi
if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then 
    err "❌ LỖI: Trùng IP Public. AWS chưa gán Elastic IP thứ 2?"
fi

# ==========================================
# 7. KHỞI CHẠY NODES
# ==========================================
log "🚀 Đang Pull images (Song song)..."
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
if [[ "$ARCH" != "aarch64" ]]; then
  docker pull $IMG_PR >/dev/null 2>&1 &
fi
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

  # Proxyrack (Chỉ chạy khi không phải ARM)
  if [[ "$ARCH" != "aarch64" ]]; then
    local PR_UUID=""
    local CLEAN_IP="${BIND_IP//./}"
    local PR_NAME="ProxyrackNode${ID}IP${CLEAN_IP}"

    # --- SỬA LOGIC UUID TẠI ĐÂY ---
    if [ -f "$MARKER_V2" ]; then
        # Máy mới: Đã có cờ V2 -> Dùng MAC + IP
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    elif [ -f "$MARKER_FILE" ]; then
        # Máy cũ: Có cờ V1 -> Chỉ dùng IP
        PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    else
        # Lần đầu: Dùng MAC + IP làm chuẩn mới
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    fi

    docker run -d --network $NET --restart always $DNS_OPTS \
      -e UUID="$PR_UUID" \
      --name proxyrack$ID $IMG_PR >/dev/null

    PR_UUIDS+=("$PR_UUID")
    PR_NAMES+=("$PR_NAME")
  fi
}

run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

log "==== DONE STARTING CONTAINERS - Vinh Cao ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ==========================================
# 8. GỌI API PROXYRACK
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    echo "------------------------------------------------------"
    # Kiểm tra nếu đã có bất kỳ file cờ nào (V1 hoặc V2)
    if [ -f "$MARKER_FILE" ] || [ -f "$MARKER_V2" ]; then
        log "✅ HỆ THỐNG GHI NHẬN: Đã đăng ký Proxyrack trước đó."
        log "👉 Container đã nhận lại UUID cũ. BỎ QUA thời gian chờ và API!"
    else
        warn "⏳ Đang đợi 2 phút để thiết bị Proxyrack kết nối..."
        for i in {120..1}; do
            printf "\r⏳ Còn lại %3d giây..." "$i"
            sleep 1
        done
        echo -e "\n"

        log "🚀 Đang gọi API thêm thiết bị Proxyrack..."
        for j in "${!PR_UUIDS[@]}"; do
            UUID="${PR_UUIDS[$j]}"
            NAME="${PR_NAMES[$j]}"
            
            log "Gửi đăng ký cho: $NAME"
            
            API_RESPONSE=$(curl -s -X POST https://peer.proxyrack.com/api/device/add \
              -H "Api-Key: $TOKEN_PROXYRACK_API" \
              -H "Content-Type: application/json" \
              -H "Accept: application/json" \
              -d "{\"device_id\":\"$UUID\",\"device_name\":\"$NAME\"}")
            
            echo "$API_RESPONSE" | jq . 2>/dev/null || echo "$API_RESPONSE"
        done
        
        # Đăng ký xong lần đầu thì tạo cờ V2 để khóa cơ chế MAC
        touch "$MARKER_V2"
        log "✅ Đã lưu cờ đánh dấu thế hệ mới tại $MARKER_V2"
    fi
fi
