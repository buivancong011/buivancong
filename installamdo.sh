#!/bin/bash
set -e

# ==========================================
# 1. CẤU HÌNH TÀI KHOẢN (SỬA 1 LẦN DÙNG MÃI MÃI)
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

# ==== CẤU HÌNH TỐI ƯU DOCKER ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
# Giới hạn log tối đa 30MB mỗi container (3 file x 10MB) để chống đầy ổ cứng
LOG_OPTS="--log-opt max-size=10m --log-opt max-file=3"

log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. CHỐT CHẶN 0: KIỂM TRA MẠNG TỔNG
# ==========================================
log "Kiểm tra kết nối Internet sơ bộ..."
if ! curl -s --connect-timeout 5 https://1.1.1.1 > /dev/null; then
    err "VPS không có Internet hoặc DNS lỗi! Dừng script ngay."
fi

# ==========================================
# 3. TỐI ƯU HỆ THỐNG & CÀI ĐẶT
# ==========================================
log "Dọn dẹp & cài đặt tools cho Debian/Ubuntu..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq && sudo apt-get install -y -q jq coreutils curl iproute2 iptables >/dev/null 2>&1 || true

log "Cấu hình tối ưu BBR, Swappiness..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

if [ ! -f /swapfile ]; then
    log "Tạo Swap 2GB (Chống tràn RAM)..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null 2>&1 && sudo swapon /swapfile >/dev/null 2>&1
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

if ! command -v docker &> /dev/null; then
    log "Cài đặt Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    sudo systemctl enable --now docker
fi

docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP THÔNG MINH (AUTO-SCALING ARRAY)
# ==========================================
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
[ -z "$MAIN_IFACE" ] && err "Không tìm thấy Interface mạng chính!"
log "Interface chính: $MAIN_IFACE"

mapfile -t ALL_IPS < <(ip -o -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $4}' | cut -d/ -f1)
TOTAL_IPS=${#ALL_IPS[@]}

if [ "$TOTAL_IPS" -eq 0 ]; then
    err "LỖI: Không tìm thấy bất kỳ IP nào trên $MAIN_IFACE!"
fi

log "🔥 TỰ ĐỘNG NHẬN DIỆN: Tìm thấy $TOTAL_IPS IP Private trên máy."
for i in "${!ALL_IPS[@]}"; do
    log "  -> IP Cụm $((i+1)): ${ALL_IPS[$i]}"
done

# ==========================================
# 5. MẠNG & IPTABLES
# ==========================================
log "Đang tự động cấu hình $TOTAL_IPS mạng Docker và SNAT..."
sudo iptables -t nat -F POSTROUTING 2>/dev/null || true

for i in "${!ALL_IPS[@]}"; do
    INDEX=$((i+1))
    BIND_IP="${ALL_IPS[$i]}"
    SUBNET="192.168.10${INDEX}.0/24"
    NET_NAME="my_network_$INDEX"

    docker network create "$NET_NAME" --driver bridge --subnet "$SUBNET" >/dev/null 2>&1 || true
    sudo iptables -t nat -I POSTROUTING -s "$SUBNET" -j SNAT --to-source "$BIND_IP"
done

log "⏳ Chờ 3s cập nhật cấu hình mạng..."
sleep 3

# ==========================================
# 6. CHỐT CHẶN SINH TỬ: KIỂM TRA MẠNG ĐẦU RA
# ==========================================
log "🕵️ Đang xác thực IP Public thực tế cho toàn bộ $TOTAL_IPS cụm..."
declare -a DETECTED_PUBLIC_IPS

for i in "${!ALL_IPS[@]}"; do
    INDEX=$((i+1))
    NET_NAME="my_network_$INDEX"
    
    PUB_IP=$(docker run --rm --network "$NET_NAME" curlimages/curl:latest -s --max-time 15 https://api.ipify.org || echo "FAIL")

    if [ "$PUB_IP" == "FAIL" ]; then
        err "❌ Cụm $INDEX (Local IP: ${ALL_IPS[$i]}) MẤT MẠNG INTERNET! Dừng toàn bộ hệ thống để bảo vệ."
    fi

    if [[ " ${DETECTED_PUBLIC_IPS[@]} " =~ " ${PUB_IP} " ]]; then
        err "❌ LỖI TRÙNG IP: Cụm $INDEX đang thoát ra bằng IP Public ($PUB_IP) đã bị cụm khác dùng! Dừng ngay!"
    fi

    DETECTED_PUBLIC_IPS+=("$PUB_IP")
    log "  ✅ Cụm $INDEX thông suốt -> Public IP: $PUB_IP"
done

log "🎉 TUYỆT VỜI: Toàn bộ $TOTAL_IPS cụm đã tách IP Public thành công và độc lập 100%!"

# ==========================================
# 7. KHỞI CHẠY NODES (TÍCH HỢP LOG_OPTS & AUTO VOLUME)
# ==========================================
log "🚀 Đang Pull images (Song song)..."
for img in "traffmonetizer/cli_v2:latest" "mysteriumnetwork/myst:latest" "techroy23/docker-urnetwork:latest" "earnfm/earnfm-client:latest" "repocket/repocket:latest" "bitping/bitpingd:latest"; do
    docker pull $img >/dev/null 2>&1 &
done
wait

run_nodes() {
    local INDEX=$1; local NET=$2; local BIND_IP=$3
    
    # Traffmonetizer
    docker run -d --network $NET --restart always $LOG_OPTS --name tm$INDEX $DNS_OPTS traffmonetizer/cli_v2:latest start accept --token "$TOKEN_TM" >/dev/null
    
    # Mysterium
    docker run -d --network $NET --cap-add NET_ADMIN $LOG_OPTS $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst$INDEX -v myst-data$INDEX:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions >/dev/null
    
    # UrNetwork
    docker run -d --network $NET --restart always --cap-add NET_ADMIN $LOG_OPTS $DNS_OPTS --name urnetwork$INDEX -v ur_data$INDEX:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" techroy23/docker-urnetwork:latest >/dev/null
    
    # EarnFM
    docker run -d --network $NET --restart always $LOG_OPTS $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$INDEX earnfm/earnfm-client:latest >/dev/null
    
    # Repocket
    docker run -d --network $NET --restart always $LOG_OPTS $DNS_OPTS --name repocket$INDEX -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" repocket/repocket:latest >/dev/null

    # Bitping
    docker run -d --network $NET --restart unless-stopped $LOG_OPTS $DNS_OPTS --name bitping$INDEX -v bitping_data$INDEX:/root/.bitpingd -e BITPING_EMAIL="$EMAIL_BITPING" -e BITPING_PASSWORD="$PASS_BITPING" bitping/bitpingd:latest >/dev/null
}

for i in "${!ALL_IPS[@]}"; do
    INDEX=$((i+1))
    run_nodes "$INDEX" "my_network_$INDEX" "${ALL_IPS[$i]}"
done

log "==== DONE STARTING $TOTAL_IPS CONTAINERS GROUP ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
