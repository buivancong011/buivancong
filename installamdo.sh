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

# ==== Cấu hình Marker cho Proxyrack ====
DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
MARKER_FILE="/root/.proxyrack_registered_vinh"       # File cờ máy cũ (V1)
MARKER_V2="/root/.proxyrack_v2_mac_vinh"            # File cờ máy mới (V2)

declare -a PR_UUIDS
declare -a PR_NAMES

log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. CHỌN IMAGE & PHÂN TÁCH KIẾN TRÚC
# ==========================================
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  IMG_TM="traffmonetizer/cli_v2:arm64v8"
else
  IMG_TM="traffmonetizer/cli_v2:latest"
fi
IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"
IMG_PR="proxyrack/pop:latest"

# ==========================================
# 3. CHUẨN BỊ HỆ THỐNG
# ==========================================
log "Chuẩn bị hệ thống..."
sudo apt-get update -qq && sudo apt-get install -y -q curl jq coreutils iproute2 iptables >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# Tối ưu Sysctl & Swap
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

if [ ! -f /swapfile ]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile && sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

log "Dọn dẹp container cũ..."
[ -n "$(docker ps -aq)" ] && docker rm -f $(docker ps -aq) >/dev/null 2>&1
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP & CẤU HÌNH MẠNG
# ==========================================
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
IP_ALLA=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '1p')
IP_ALLB=$(ip -4 addr show dev $MAIN_IFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1 | sed -n '2p')

ensure_network() {
  local NET=$1; local SUB=$2
  docker network inspect "$NET" >/dev/null 2>&1 && docker network rm "$NET" >/dev/null
  docker network create "$NET" --driver bridge --subnet "$SUB" >/dev/null
}
ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}
sleep 5

# ==========================================
# 5. KHỞI CHẠY NODES (SỬA LOGIC PROXYRACK)
# ==========================================
run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2; local SUFFIX=$3
  
  docker run -d --network $NET --restart always --name tm_$SUFFIX $DNS_OPTS $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst_$SUFFIX -v myst-data${ID}:/var/lib/mysterium-node --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
  docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS --name ur_$SUFFIX -v ur_data_${SUFFIX}:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
  docker run -d --network $NET --restart always $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earn_$SUFFIX $IMG_EARN >/dev/null
  docker run -d --network $NET --restart always $DNS_OPTS --name rp_$SUFFIX -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

  # --- PHẦN SỬA CHÍNH: PROXYRACK UUID ---
  if [[ "$ARCH" != "aarch64" ]]; then
    local PR_UUID=""
    local PR_NAME="PR_Node${ID}_${BIND_IP//./}"

    # Kiểm tra VPS cũ hay mới để lấy UUID chuẩn
    if [ -f "$MARKER_V2" ]; then
        # Máy thế hệ mới: Dùng MAC + IP
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    elif [ -f "$MARKER_FILE" ]; then
        # Máy cũ (V1): Chỉ dùng IP để không nhảy ID web
        PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    else
        # Cài mới: Dùng MAC + IP làm chuẩn V2
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    fi

    docker run -d --network $NET --restart always $DNS_OPTS -e UUID="$PR_UUID" --name pr_$SUFFIX $IMG_PR >/dev/null
    PR_UUIDS+=("$PR_UUID")
    PR_NAMES+=("$PR_NAME")
  fi
}

run_node_group 1 "$IP_ALLA" "main"
run_node_group 2 "$IP_ALLB" "sub"

# ==========================================
# 6. GỌI API PROXYRACK (CHỈ GỌI KHI CHƯA ĐĂNG KÝ)
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    # Nếu đã có file cờ V1 hoặc V2 thì bỏ qua hết
    if [ -f "$MARKER_FILE" ] || [ -f "$MARKER_V2" ]; then
        log "✅ Đã đăng ký Proxyrack (V1 hoặc V2). Bỏ qua thời gian chờ và API."
    else
        warn "⏳ Đợi 2 phút đăng ký thiết bị lần đầu..."
        for i in {120..1}; do printf "\r⏳ Còn lại %3d giây..." "$i"; sleep 1; done; echo -e "\n"
        for j in "${!PR_UUIDS[@]}"; do
            curl -s -X POST https://peer.proxyrack.com/api/device/add \
              -H "Api-Key: $TOKEN_PROXYRACK_API" -H "Content-Type: application/json" \
              -d "{\"device_id\":\"${PR_UUIDS[$j]}\",\"device_name\":\"${PR_NAMES[$j]}\"}" >/dev/null
        done
        touch "$MARKER_V2"
        log "✅ Đã lưu cờ V2 (MAC). Chạy lại lần sau sẽ không phải đợi."
    fi
fi

log "==== DONE - Vinh Cao ===="
docker ps --format "table {{.Names}}\t{{.Status}}"
