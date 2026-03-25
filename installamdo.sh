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
TOKEN_PROXYRACK_API="KK3M5OBY1TDBZ97KMJBBYKIV4PE9DIKUXIERYWVA"

# DNS Cloudflare
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"

# Marker file cho Proxyrack
MARKER_FILE="/root/.proxyrack_registered_vinh"

# Mảng lưu thông tin để gọi API Proxyrack
declare -a PR_UUIDS
declare -a PR_NAMES

# Interface chính (Debian 12 DO thường là eth0)
IFACE="eth0"

# Image
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  echo -e "\e[32m[INFO] Detected ARM64 CPU. Proxyrack tự động bỏ qua.\e[0m"
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  echo -e "\e[32m[INFO] Detected AMD64/x86 CPU. Proxyrack sẵn sàng.\e[0m"
  IMG_TM="traffmonetizer/cli_v2:latest"
fi
IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"
IMG_PR="proxyrack/pop:latest"

# Logger
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. CHUẨN BỊ DEBIAN
# ==========================================
log "Update hệ thống & cài tools..."
sudo apt-get update -q
# Bổ sung thêm jq và coreutils cho Proxyrack
sudo apt-get install -y curl net-tools grep iptables jq coreutils

if ! command -v docker &> /dev/null; then
  log "Cài Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# ==== 2.5. CẤU HÌNH TỐI ƯU (SYSCTL & SWAP) ====
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

# ==========================================
# 3. LẤY IP (THEO CÁCH CỦA BẠN - IP BRIEF)
# ==========================================
# Lệnh này lấy dòng chứa eth0, cột 3 là IP A, cột 4 là IP B (bỏ qua subnet mask)
IP_ALLA=$(/sbin/ip -4 -br addr show scope global $IFACE | awk '{gsub(/\/.*/,"",$3); print $3}')
IP_ALLB=$(/sbin/ip -4 -br addr show scope global $IFACE | awk '{gsub(/\/.*/,"",$4); print $4}')

log "--- KẾT QUẢ QUÉT IP ---"
if [ -z "$IP_ALLA" ]; then 
    err "Không tìm thấy IP nào trên $IFACE!"
else
    log "IP A (Chính): $IP_ALLA"
fi

if [ -z "$IP_ALLB" ]; then
    warn "⚠️  Chỉ tìm thấy 1 IP. Script sẽ chạy chế độ 1 luồng (hoặc 2 luồng chung 1 IP)."
    IP_ALLB=$IP_ALLA
else
    log "IP B (Phụ):   $IP_ALLB"
fi

# ==========================================
# 4. NETWORK & SNAT
# ==========================================
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

ensure_network() {
  local NET=$1; local SUB=$2
  docker network create "$NET" --driver bridge --subnet "$SUB" >/dev/null 2>&1 || true
}
ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

log "Cấu hình SNAT (IP Masquerade)..."
# Xóa rule cũ
sudo iptables -t nat -F POSTROUTING

# Rule SNAT: Ép traffic từ subnet ra đúng source IP đã lấy được
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source $IP_ALLA
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source $IP_ALLB

sleep 2

# ==========================================
# 5. CHECK IP OUTPUT (KIỂM TRA THỰC TẾ)
# ==========================================
get_public_ip() {
    local NET=$1
    docker run --rm --network "$NET" $DNS_OPTS curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Check IP Public đầu ra..."
PUB_1=$(get_public_ip "my_network_1")
PUB_2=$(get_public_ip "my_network_2")

log "👉 Node 1 (IP $IP_ALLA) -> Public: $PUB_1"
log "👉 Node 2 (IP $IP_ALLB) -> Public: $PUB_2"

if [ "$PUB_1" == "$PUB_2" ] && [ "$IP_ALLA" != "$IP_ALLB" ]; then
    warn "⚠️  CẢNH BÁO: IP Output đang trùng nhau ($PUB_1)."
    warn "Nguyên nhân: DigitalOcean có thể đang NAT IP phụ $IP_ALLB qua IP chính."
fi

# ==========================================
# 6. KHỞI CHẠY NODE
# ==========================================
log "🚀 Start Nodes..."

# Kéo image song song cho nhanh
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
if [[ "$ARCH" != "aarch64" ]]; then
  docker pull $IMG_PR >/dev/null 2>&1 &
fi
wait

run_nodes() {
    # Thêm biến INDEX để xác định số thứ tự (1 hoặc 2) cho volume Mysterium
    local INDEX=$1
    local NET=$2
    local BIND_IP=$3
    local SUFFIX=$4
    
    # Traffmonetizer
    docker run -d --network $NET --restart always --name tm_$SUFFIX $DNS_OPTS \
      $IMG_TM start accept --token "$TOKEN_TM" >/dev/null

    # Mysterium (GIỮ NGUYÊN SCRIPT GỐC CỦA ÔNG)
    docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS \
      -p ${BIND_IP}:4449:4449 \
      --name myst_$SUFFIX -v myst-data${INDEX}:/var/lib/mysterium-node \
      --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null

    # UrNetwork
    docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS \
      --name ur_$SUFFIX -v ur_data_$SUFFIX:/var/lib/vnstat \
      -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null

    # EarnFM
    docker run -d --network $NET --restart always $DNS_OPTS \
      -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earn_$SUFFIX $IMG_EARN >/dev/null

    # Repocket
    docker run -d --network $NET --restart always $DNS_OPTS \
      --name rp_$SUFFIX \
      -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

    # Proxyrack (Chỉ chạy khi không phải ARM)
    if [[ "$ARCH" != "aarch64" ]]; then
      # Băm IP ra UUID cố định & format lại tên
      local PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
      local CLEAN_IP="${BIND_IP//./}"
      local PR_NAME="ProxyrackNode${INDEX}IP${CLEAN_IP}"

      docker run -d --network $NET --restart always $DNS_OPTS \
        -e UUID="$PR_UUID" \
        --name pr_$SUFFIX $IMG_PR >/dev/null

      # Thêm vào mảng để gọi API
      PR_UUIDS+=("$PR_UUID")
      PR_NAMES+=("$PR_NAME")
    fi
}

# Chạy Node 1 (Index 1 -> Volume myst-data1)
run_nodes 1 "my_network_1" "$IP_ALLA" "main"

# Chạy Node 2 (Index 2 -> Volume myst-data2)
if [ -n "$IP_ALLB" ] && [ "$IP_ALLB" != "$IP_ALLA" ]; then
    run_nodes 2 "my_network_2" "$IP_ALLB" "sub"
elif [ "$IP_ALLB" == "$IP_ALLA" ]; then
    # Trường hợp 1 IP chạy 2 node
    log "Chạy node 2 trên cùng IP chính..."
    run_nodes 2 "my_network_2" "$IP_ALLA" "sub"
fi

log "==== DONE ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ==========================================
# 7. GỌI API PROXYRACK
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    echo "------------------------------------------------------"
    if [ -f "$MARKER_FILE" ]; then
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
        
        touch "$MARKER_FILE"
        log "✅ Đã lưu cờ đánh dấu tại $MARKER_FILE"
    fi
fi
