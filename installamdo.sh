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
TOKEN_PROXYRACK_API="KK3M5OBY1TDBZ97KMJBBYKIV4PE9DIKUXIERYWVA"

# ==== CẤU HÌNH MARKERS ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
MARKER_V1="/root/.proxyrack_registered_vinh"
MARKER_V2="/root/.proxyrack_v2_mac_vinh"

declare -a PR_UUIDS
declare -a PR_NAMES

log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. KIỂM TRA HỆ THỐNG
# ==========================================
log "🔍 Đang kiểm tra kiến trúc CPU..."
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
    warn "Detected ARM64. Proxyrack sẽ bị bỏ qua."
else
    log "Detected AMD64. Proxyrack sẵn sàng."
fi

# ==========================================
# 3. CHUẨN BỊ & DỌN DẸP (HIỂN THỊ CHI TIẾT)
# ==========================================
log "🧹 Đang dọn dẹp các container cũ để giải phóng RAM..."
containers=$(docker ps -aq)
if [ -n "$containers" ]; then
    docker rm -f $containers
fi
docker network prune -f

log "⚙️  Đang cài đặt/cập nhật các công cụ bổ trợ (jq, curl, iproute2)..."
sudo apt-get update -q
sudo apt-get install -y jq coreutils curl iproute2 iptables

log "🚀 Đang tối ưu thông số mạng BBR và Swappiness..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf

if [ ! -f /swapfile ]; then
    log "💾 Đang tạo Swap 2GB (Bảo hiểm cho RAM)..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# ==========================================
# 4. DÒ TÌM IP VÀ MẠNG
# ==========================================
log "📡 Đang dò tìm Interface mạng chính..."
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
log "Interface chính xác định: $MAIN_IFACE"

IP_ALLA=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '1p')
IP_ALLB=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '2p')

log "👉 IP A: $IP_ALLA"
log "👉 IP B: $IP_ALLB"

# ==========================================
# 5. KHỞI CHẠY NODES (LOGIC PROXYRACK CHUẨN)
# ==========================================
run_node_group() {
    local ID=$1; local NET="my_network_$1"; local BIND_IP=$2; local SUFFIX=$3
    [ -z "$BIND_IP" ] && return 0

    log "🏗️  Đang thiết lập mạng nội bộ cho IP: $BIND_IP..."
    docker network create "$NET" --driver bridge --subnet "192.168.$((32+ID)).0/24" || true
    sudo iptables -t nat -I POSTROUTING -s "192.168.$((32+ID)).0/24" -j SNAT --to-source "$BIND_IP"

    log "🚢 Đang chạy cụm container $SUFFIX..."
    docker run -d --network $NET --restart always --name tm_$SUFFIX $DNS_OPTS traffmonetizer/cli_v2:latest start accept --token "$TOKEN_TM"
    docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst_$SUFFIX -v myst-data${ID}:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
    docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS --name ur_$SUFFIX -v ur_data_${SUFFIX}:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" techroy23/docker-urnetwork:latest
    docker run -d --network $NET --restart always $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earn_$SUFFIX earnfm/earnfm-client:latest
    docker run -d --network $NET --restart always $DNS_OPTS --name rp_$SUFFIX -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" repocket/repocket:latest

    if [[ "$ARCH" != "aarch64" ]]; then
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        local PR_UUID=""
        if [ -f "$MARKER_V2" ]; then
            PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
        elif [ -f "$MARKER_V1" ]; then
            PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
        else
            PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
        fi
        docker run -d --network $NET --restart always $DNS_OPTS -e UUID="$PR_UUID" --name pr_$SUFFIX proxyrack/pop:latest
        PR_UUIDS+=("$PR_UUID"); PR_NAMES+=("PR_Node${ID}_${BIND_IP//./}")
    fi
}

run_node_group 1 "$IP_ALLA" "main"
run_node_group 2 "$IP_ALLB" "sub"

# ==========================================
# 6. ĐĂNG KÝ PROXYRACK (CÓ ĐẾM NGƯỢC)
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    echo "------------------------------------------------------"
    if [ -f "$MARKER_V1" ] || [ -f "$MARKER_V2" ]; then
        log "✅ Hệ thống ghi nhận thiết bị đã đăng ký trước đó."
        log "👉 Giữ nguyên UUID. Bỏ qua thời gian chờ API."
    else
        warn "⏳ Đang đợi 2 phút để thiết bị kết nối Server lần đầu..."
        for i in {120..1}; do printf "\r⏳ Còn lại %3d giây..." "$i"; sleep 1; done; echo ""
        
        log "🚀 Đang gọi API Proxyrack để kích hoạt thiết bị..."
        for j in "${!PR_UUIDS[@]}"; do
            UUID="${PR_UUIDS[$j]}"
            NAME="${PR_NAMES[$j]}"
            log "Đăng ký: $NAME"
            curl -s -X POST https://peer.proxyrack.com/api/device/add \
              -H "Api-Key: $TOKEN_PROXYRACK_API" -H "Content-Type: application/json" \
              -d "{\"device_id\":\"$UUID\",\"device_name\":\"$NAME\"}" | jq . || echo "Đã gửi yêu cầu."
        done
        touch "$MARKER_V2"
    fi
fi

log "========================================================"
log "🎉 TOÀN BỘ TIẾN TRÌNH HOÀN TẤT - CHÚC ÔNG CAO NHIỀU TIỀN!"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
