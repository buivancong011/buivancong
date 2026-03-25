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

DNS_OPTS="--dns 1.1.1.1 --dns 1.0.0.1"
MARKER_FILE="/root/.proxyrack_registered_vinh"
declare -a PR_UUIDS
declare -a PR_NAMES
IFACE="eth0"

# Logger chuyên nghiệp
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# CHỐT CHẶN 0: KIỂM TRA INTERNET TỔNG THỂ
# ==========================================
log "Kiểm tra kết nối Internet sơ bộ..."
if ! curl -s --connect-timeout 5 https://1.1.1.1 > /dev/null; then
    err "VPS hiện không có Internet hoặc DNS lỗi! Dừng script ngay."
fi

# Image
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
# 2. CHUẨN BỊ DEBIAN
# ==========================================
log "Update hệ thống & cài tools..."
sudo apt-get update -q && sudo apt-get install -y curl net-tools grep iptables jq coreutils

if ! command -v docker &> /dev/null; then
  log "Cài Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
fi

# CHỐT CHẶN 1: KIỂM TRA TRẠNG THÁI DOCKER
if ! sudo systemctl is-active --quiet docker; then
    err "Docker cài xong nhưng không khởi động được! Hãy kiểm tra lại VPS."
fi

# ==== 2.5. TỐI ƯU HỆ THỐNG ====
sudo tee /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null <<EOF
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-mmo-node-tuning.conf >/dev/null 2>&1 || true

if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

# ==========================================
# 3. LẤY IP & CHỐT CHẶN GÁN IP PHỤ
# ==========================================
IP_ALLA=$(/sbin/ip -4 -br addr show scope global $IFACE | awk '{gsub(/\/.*/,"",$3); print $3}')
IP_ALLB=$(/sbin/ip -4 -br addr show scope global $IFACE | awk '{gsub(/\/.*/,"",$4); print $4}')

log "--- KẾT QUẢ QUÉT IP NỘI BỘ ---"
[ -z "$IP_ALLA" ] && err "Không tìm thấy IP Chính trên $IFACE!"
log "IP A (Chính): $IP_ALLA"

# CHỐT CHẶN 2: ÉP PHẢI CÓ 2 IP NẾU MUỐN CHẠY MULTI-NODE
if [ -z "$IP_ALLB" ]; then
    err "KHÔNG tìm thấy IP phụ! Để bảo vệ tài khoản, script sẽ không chạy 2 node trên cùng 1 IP. Hãy gán thêm IP Public cho VPS."
fi
log "IP B (Phụ):   $IP_ALLB"

# ==========================================
# 4. NETWORK & SNAT
# ==========================================
log "Dọn dẹp container cũ..."
docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1

ensure_network() {
  docker network create "$1" --driver bridge --subnet "$2" >/dev/null 2>&1 || true
}
ensure_network "my_network_1" "192.168.33.0/24"
ensure_network "my_network_2" "192.168.34.0/24"

log "Cấu hình SNAT..."
sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source $IP_ALLA
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source $IP_ALLB

# ==========================================
# 5. CHỐT CHẶN SINH TỬ: KIỂM TRA IP PUBLIC ĐẦU RA
# ==========================================
get_public_ip() {
    docker run --rm --network "$1" $DNS_OPTS curlimages/curl:latest -s --max-time 15 https://api.ipify.org || echo "FAIL"
}

log "🕵️ Đang kiểm tra IP Public thực tế..."
PUB_1=$(get_public_ip "my_network_1")
PUB_2=$(get_public_ip "my_network_2")

log "👉 Cụm 1 thoát ra bằng: $PUB_1"
log "👉 Cụm 2 thoát ra bằng: $PUB_2"

# CHỐT CHẶN 3: KIỂM TRA MẠNG TỪNG CỤM
if [ "$PUB_1" == "FAIL" ] || [ "$PUB_2" == "FAIL" ]; then
    err "LỖI MẠNG: Một trong các cụm Docker không thể kết nối Internet. Dừng ngay!"
fi

# CHỐT CHẶN 4: CHỐNG TRÙNG IP (MULTI-IP SAFETY)
if [ "$PUB_1" == "$PUB_2" ]; then
    err "LỖI TRÙNG IP: Cả 2 luồng đang thoát ra cùng 1 IP Public ($PUB_1). Dừng script để bảo vệ Acc!"
fi
log "✅ TUYỆT VỜI: Mạng đã tách luồng thành công."

# ==========================================
# 6. KHỞI CHẠY NODE
# ==========================================
log "🚀 Start Nodes..."
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
done
[[ "$ARCH" != "aarch64" ]] && docker pull $IMG_PR >/dev/null 2>&1 &
wait

run_nodes() {
    local INDEX=$1; local NET=$2; local BIND_IP=$3; local SUFFIX=$4
    docker run -d --network $NET --restart always --name tm_$SUFFIX $DNS_OPTS $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
    docker run -d --network $NET --cap-add NET_ADMIN $DNS_OPTS -p ${BIND_IP}:4449:4449 --name myst_$SUFFIX -v myst-data${INDEX}:/var/lib/mysterium-node --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
    docker run -d --network $NET --restart always --cap-add NET_ADMIN $DNS_OPTS --name ur_$SUFFIX -v ur_data_$SUFFIX:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
    docker run -d --network $NET --restart always $DNS_OPTS -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earn_$SUFFIX $IMG_EARN >/dev/null
    docker run -d --network $NET --restart always $DNS_OPTS --name rp_$SUFFIX -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null

    if [[ "$ARCH" != "aarch64" ]]; then
      local PR_UUID=""
      local MAC_ADDR=$(ip link show dev $IFACE 2>/dev/null | awk '/ether/ {print $2}')
      [ -z "$MAC_ADDR" ] && MAC_ADDR="NOMAC"
      
      if [ -f "$MARKER_FILE" ]; then
          PR_UUID=$(echo -n "${BIND_IP}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
      else
          PR_UUID=$(echo -n "${BIND_IP}-${MAC_ADDR}-Proxyrack-Vinh" | sha256sum | awk '{print toupper($1)}')
      fi
      docker run -d --network $NET --restart always $DNS_OPTS -e UUID="$PR_UUID" --name pr_$SUFFIX $IMG_PR >/dev/null
      PR_UUIDS+=("$PR_UUID"); PR_NAMES+=("PR_${INDEX}_${BIND_IP//./}")
    fi
}

run_nodes 1 "my_network_1" "$IP_ALLA" "main"
run_nodes 2 "my_network_2" "$IP_ALLB" "sub"

log "==== TẤT CẢ OK - VINH CAO ===="
docker ps --format "table {{.Names}}\t{{.Status}}"

# ==========================================
# 7. GỌI API PROXYRACK
# ==========================================
if [ ${#PR_UUIDS[@]} -gt 0 ] && [ ! -f "$MARKER_FILE" ]; then
    warn "⏳ Chờ 2 phút để các Node kết nối..."
    sleep 120
    for j in "${!PR_UUIDS[@]}"; do
        curl -s -X POST https://peer.proxyrack.com/api/device/add -H "Api-Key: $TOKEN_PROXYRACK_API" -H "Content-Type: application/json" -d "{\"device_id\":\"${PR_UUIDS[$j]}\",\"device_name\":\"${PR_NAMES[$j]}\"}" | jq . || true
    done
    touch "$MARKER_FILE"
fi
