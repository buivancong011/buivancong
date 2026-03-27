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
ARCH=$(uname -m)
log "Đang kiểm tra kiến trúc CPU..."
if [[ "$ARCH" == "aarch64" ]]; then
    warn "Detected ARM64. Proxyrack sẽ bị bỏ qua."
else
    log "Detected AMD64. Proxyrack sẵn sàng."
fi

# ==========================================
# 3. CHUẨN BỊ (PHONG CÁCH AWS)
# ==========================================
log "Dọn dẹp hệ thống..."
sudo apt-get update -qq && sudo apt-get install -y -q jq coreutils curl iproute2 iptables >/dev/null 2>&1 || true

log "Cấu hình bộ nhớ đệm mạng, BBR và Swappiness..."
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

if [ ! -f /swapfile ]; then
    log "Cấu hình Swap 2GB (Chống tràn RAM)..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null 2>&1
    sudo swapon /swapfile >/dev/null 2>&1
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
    log "Swap file đã tồn tại, bỏ qua bước tạo mới."
fi

log "Dọn dẹp container & network cũ..."
[ -n "$(docker ps -aq)" ] && docker rm -f $(docker ps -aq) >/dev/null 2>&1
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP THÔNG MINH (DETAIL LOG)
# ==========================================
log "Đang tự động dò tìm Interface mạng chính..."
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
[ -z "$MAIN_IFACE" ] && err "Không tìm thấy Interface!"
log "Đã tìm thấy Interface: $MAIN_IFACE"

IP_ALLA=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '1p')
IP_ALLB=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '2p')

[ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ] || log "👉 IP Bắt được: A=$IP_ALLA | B=$IP_ALLB"

# ==========================================
# 5. MẠNG & IPTABLES
# ==========================================
log "Cấu hình IPTables SNAT..."
docker network create "my_network_1" --driver bridge --subnet "192.168.33.0/24" >/dev/null 2>&1 || true
docker network create "my_network_2" --driver bridge --subnet "192.168.34.0/24" >/dev/null 2>&1 || true

sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

log "⏳ Chờ 5s cập nhật mạng..."
sleep 5

# ==========================================
# 6. XÁC THỰC IP PUBLIC (BƯỚC LÀM NÊN ĐẲNG CẤP)
# ==========================================
get_public_ip() {
    docker run --rm --network "$1" curlimages/curl:latest -s --max-time 10 https://api.ipify.org || echo "FAIL"
}

log "🕵️ Đang xác thực IP Public thực tế..."
PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "    Check 1: Source $IP_ALLA -> Exit: [$PUB_IP_1]"
log "    Check 2: Source $IP_ALLB -> Exit: [$PUB_IP_2]"

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then
    warn "CẢNH BÁO: Hai luồng đang đi ra chung 1 IP Public!"
fi

# ==========================================
# 7. KHỞI CHẠY NODES (AWS STYLE)
# ==========================================
log "🚀 Đang Pull images (Song song)..."
for img in "traffmonetizer/cli_v2:latest" "mysteriumnetwork/myst:latest" "techroy23/docker-urnetwork:latest" "earnfm/earnfm-client:latest" "repocket/repocket:latest"; do
    docker pull $img >/dev/null 2>&1 &
done
[[ "$ARCH" != "aarch64" ]] && docker pull proxyrack/pop:latest >/dev/null 2>&1 &
wait

run_node_group() {
    local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
    [ -z "$BIND_IP" ] && return 0

    docker run -d --network $NET --restart always --name tm$ID $DNS_OPTS traffmonetizer/cli_v2:latest start accept --token "$TOKEN_TM" >/dev/null
    docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst$ID -v myst-data$ID:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions >/dev/null
    docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" techroy23/docker-urnetwork:latest >/dev/null
    docker run -d --network $NET --restart always $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$ID earnfm/earnfm-client:latest >/dev/null
    docker run -d --network $NET --restart always $DNS_OPTS --name repocket$ID -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" repocket/repocket:latest >/dev/null

    if [[ "$ARCH" != "aarch64" ]]; then
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address 2>/dev/null || echo "NOMAC")
        local PR_UUID=""
        if [ -f "$MARKER_V2" ]; then
            PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
        elif [ -f "$MARKER_V1" ]; then
            PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
        else
            PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
        fi
        docker run -d --network $NET --restart always $DNS_OPTS -e UUID="$PR_UUID" --name proxyrack$ID proxyrack/pop:latest >/dev/null
        PR_UUIDS+=("$PR_UUID"); PR_NAMES+=("PRNode${ID}_${BIND_IP//./}")
    fi
}

run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

log "==== DONE STARTING CONTAINERS - Vinh Cao ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ==========================================
# 8. API PROXYRACK
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    echo "------------------------------------------------------"
    if [ -f "$MARKER_V1" ] || [ -f "$MARKER_V2" ]; then
        log "✅ Đã đăng ký (V1/V2). Bỏ qua thời gian chờ."
    else
        warn "⏳ Đang đợi 2 phút để thiết bị Proxyrack kết nối..."
        for i in {120..1}; do printf "\r⏳ Còn lại %3d giây..." "$i"; sleep 1; done; echo ""
        for j in "${!PR_UUIDS[@]}"; do
            log "Đăng ký API cho: ${PR_NAMES[$j]}"
            curl -s -X POST https://peer.proxyrack.com/api/device/add \
              -H "Api-Key: $TOKEN_PROXYRACK_API" -H "Content-Type: application/json" \
              -d "{\"device_id\":\"${PR_UUIDS[$j]}\",\"device_name\":\"${PR_NAMES[$j]}\"}" >/dev/null
        done
        touch "$MARKER_V2"
        log "✅ Đã lưu cờ đánh dấu thế hệ mới."
    fi
fi
