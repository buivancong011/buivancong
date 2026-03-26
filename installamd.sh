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
MARKER_FILE="/root/.proxyrack_registered_vinh"       # Máy cũ (IP)
MARKER_V2="/root/.proxyrack_v2_mac_vinh"            # Máy mới (MAC)

declare -a PR_UUIDS
declare -a PR_NAMES

log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 2. CHỌN IMAGE THEO KIẾN TRÚC CPU
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
log "Dọn dẹp và cài đặt công cụ..."
sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true
sudo yum install -y -q jq coreutils >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

# Tối ưu Sysctl
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

# Swap 2GB
if [ ! -f /swapfile ]; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

log "Dọn dẹp container cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. BẮT IP & CẤU HÌNH MẠNG
# ==========================================
MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic $MAIN_IFACE | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n 1)

ensure_network() {
  local NET=$1; local SUB=$2
  docker network inspect "$NET" >/dev/null 2>&1 && docker network rm "$NET" >/dev/null
  docker network create "$NET" --driver bridge --subnet "$SUB" >/dev/null
}

ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

# NAT IPTables
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

sleep 5

# ==========================================
# 5. KHỞI CHẠY NODES & PROXYRACK LOGIC
# ==========================================
log "🚀 Khởi chạy Nodes..."
run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  
  docker run -d --network $NET --restart always --name tm$ID $DNS_OPTS $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst$ID -v myst-data$ID:/var/lib/mysterium-node --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
  docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
  docker run -d --network $NET --restart always $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$ID $IMG_EARN >/dev/null
  docker run -d --network $NET --restart always $DNS_OPTS --name repocket$ID -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

  if [[ "$ARCH" != "aarch64" ]]; then
    local PR_UUID=""
    local PR_NAME="ProxyrackNode${ID}IP${BIND_IP//./}"

    if [ -f "$MARKER_V2" ]; then
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    elif [ -f "$MARKER_FILE" ]; then
        PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    else
        local MAC_ADDR=$(cat /sys/class/net/$MAIN_IFACE/address)
        PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
    fi

    docker run -d --network $NET --restart always $DNS_OPTS -e UUID="$PR_UUID" --name proxyrack$ID $IMG_PR >/dev/null
    PR_UUIDS+=("$PR_UUID")
    PR_NAMES+=("$PR_NAME")
  fi
}

run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

# ==========================================
# 6. API PROXYRACK
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ]; then
    if [ -f "$MARKER_FILE" ] || [ -f "$MARKER_V2" ]; then
        log "✅ Đã đăng ký trước đó. Bỏ qua API."
    else
        warn "⏳ Đợi 2 phút kết nối lần đầu..."
        sleep 120
        for j in "${!PR_UUIDS[@]}"; do
            curl -s -X POST https://peer.proxyrack.com/api/device/add \
              -H "Api-Key: $TOKEN_PROXYRACK_API" -H "Content-Type: application/json" \
              -d "{\"device_id\":\"${PR_UUIDS[$j]}\",\"device_name\":\"${PR_NAMES[$j]}\"}" >/dev/null
        done
        touch "$MARKER_V2"
        log "✅ Đã lưu cờ V2 (MAC)."
    fi
fi

log "==== DONE - Vinh Cao ===="
docker ps --format "table {{.Names}}\t{{.Status}}"
