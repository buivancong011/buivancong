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

DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
MARKER_FILE="/root/.proxyrack_registered_vinh"
declare -a PR_UUIDS
declare -a PR_NAMES

# Hàm log chuyên nghiệp
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# CHỐT CHẶN 0: KIỂM TRA INTERNET SƠ BỘ
# ==========================================
log "Kiểm tra kết nối Internet tổng thể..."
if ! curl -s --connect-timeout 5 https://1.1.1.1 > /dev/null; then
    err "VPS hiện không có Internet hoặc DNS lỗi! Dừng script ngay."
fi

# ==========================================
# 2. CHỌN IMAGE & PHÂN TÁCH KIẾN TRÚC
# ==========================================
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  log "Detected ARM64 CPU. Proxyrack sẽ bị bỏ qua."
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  log "Detected AMD64/x86 CPU (Debian 12). Proxyrack đã sẵn sàng."
  IMG_TM="traffmonetizer/cli_v2:latest"
fi

IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"
IMG_PR="proxyrack/pop:latest"

# ==========================================
# 3. CHUẨN BỊ DEBIAN 12 & TỐI ƯU HỆ THỐNG
# ==========================================
log "Update hệ thống & cài tools (Debian 12)..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q
sudo apt-get install -y -q curl jq coreutils iproute2 iptables >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

if ! sudo systemctl is-active --quiet docker; then
    err "LỖI: Docker cài xong nhưng không khởi động được!"
fi

log "Cấu hình bộ nhớ đệm mạng, BBR và Swappiness..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

log "Cấu hình Swap 2GB (Chuẩn dd an toàn cho DO/Azure)..."
if [ ! -f /swapfile ]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
    log "Swap file đã tồn tại, bỏ qua."
fi

log "Dọn dẹp container & network cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP THÔNG MINH (TƯƠNG THÍCH DO & AZURE)
# ==========================================
log "Đang tự động dò tìm Interface mạng chính..."
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
[ -z "$MAIN_IFACE" ] && err "Không tìm thấy Interface mạng chính!"

log "Đã tìm thấy Interface: $MAIN_IFACE"

# Bộ lọc thông minh lấy chính xác 2 IP đầu tiên bất chấp định dạng DO hay Azure
IP_ALLA=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '1p')
IP_ALLB=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '2p')

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then 
    err "CHỐT CHẶN: Không lấy đủ 2 IP trên $MAIN_IFACE! Hãy kiểm tra lại cấu hình Reserved IP (DO) hoặc Secondary IP (Azure)."
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

log "Cấu hình IPTables SNAT an toàn..."
# Dùng -D trước để xóa rule cũ nếu có, sau đó -I để chèn lên đầu bảng
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

log "⏳ Chờ 5s cập nhật mạng..."
sleep 5

# ==========================================
# 6. CHỐT CHẶN SINH TỬ: KIỂM TRA IP PUBLIC
# ==========================================
get_public_ip() {
    local NET=$1
    # Bắt buộc trả về kết quả hoặc chuỗi FAIL nếu lỗi DNS/Timeout
    docker run --rm --network "$NET" $DNS_OPTS curlimages/curl:latest -s --max-time 15 https://api.ipify.org || echo "FAIL"
}

log "🕵️ Đang xác thực IP Public thực tế..."
PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "   Cụm 1 (Source $IP_ALLA) thoát ra bằng: [$PUB_IP_1]"
log "   Cụm 2 (Source $IP_ALLB) thoát ra bằng: [$PUB_IP_2]"

if [ "$PUB_IP_1" == "FAIL" ] || [ "$PUB_IP_2" == "FAIL" ]; then 
    err "❌ LỖI NGHIÊM TRỌNG: Mất mạng hoặc không thể định tuyến ra Internet! Dừng Script ngay."
fi

if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then 
    err "❌ LỖI NGHIÊM TRỌNG: Lấy IP Public trả về rỗng. Dừng Script!"
fi

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then 
    err "❌ LỖI TRÙNG IP: Cả 2 luồng đều ra chung 1 IP ($PUB_IP_1). Cấu hình NAT Gateway (Azure) hoặc Anchor IP (DO) chưa chuẩn. Dừng Script để bảo vệ Acc!"
fi

log "✅ TUYỆT VỜI: Mạng OK, 2 luồng đã được tách IP Public thành công."

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
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2; local SUFFIX=$3
  
  docker run -d --network $NET --restart always --name tm_$SUFFIX $DNS_OPTS $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst_$SUFFIX -v myst-data${ID}:/var/lib/mysterium-node --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
  docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS --name ur_$SUFFIX -v ur_data_${SUFFIX}:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
  docker run -d --network $NET --restart always $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earn_$SUFFIX $IMG_EARN >/dev/null
  docker run -d --network $NET --restart always $DNS_OPTS --name rp_$SUFFIX -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

  if [[ "$ARCH" != "aarch64" ]]; then
    local PR_UUID=""
    local MAC_ADDR=$(ip link show dev $MAIN_IFACE 2>/dev/null | awk '/ether/ {print $2}')
    [ -z "$MAC_ADDR" ] && MAC_ADDR="NOMAC"

    if [ -f "$MARKER_FILE" ]; then
        PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    else
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    fi

    docker run -d --network $NET --restart always $DNS_OPTS -e UUID="$PR_UUID" --name pr_$SUFFIX $IMG_PR >/dev/null

    PR_UUIDS+=("$PR_UUID")
    PR_NAMES+=("PR_Node${ID}_${BIND_IP//./}")
  fi
}

run_node_group 1 "$IP_ALLA" "main"
run_node_group 2 "$IP_ALLB" "sub"

log "==== TẤT CẢ OK - VINH CAO ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ==========================================
# 8. GỌI API PROXYRACK
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    echo "------------------------------------------------------"
    if [ -f "$MARKER_FILE" ]; then
        log "✅ HỆ THỐNG GHI NHẬN: Đã đăng ký Proxyrack trước đó. Bỏ qua gọi API!"
    else
        warn "⏳ Đang đợi 2 phút để các thiết bị Proxyrack khởi động & kết nối..."
        for i in {120..1}; do printf "\r⏳ Còn lại %3d giây..." "$i"; sleep 1; done; echo -e "\n"

        log "🚀 Gửi yêu cầu API đăng ký thiết bị Proxyrack..."
        for j in "${!PR_UUIDS[@]}"; do
            UUID="${PR_UUIDS[$j]}"
            NAME="${PR_NAMES[$j]}"
            
            log "Đăng ký cho: $NAME (UUID: $UUID)"
            curl -s -X POST https://peer.proxyrack.com/api/device/add \
              -H "Api-Key: $TOKEN_PROXYRACK_API" \
              -H "Content-Type: application/json" \
              -H "Accept: application/json" \
              -d "{\"device_id\":\"$UUID\",\"device_name\":\"$NAME\"}" | jq . 2>/dev/null || echo "Done"
        done
        
        touch "$MARKER_FILE"
        log "✅ Đã lưu cờ đánh dấu tại $MARKER_FILE"
    fi
fi
