#!/bin/bash
set -e  # Dừng ngay nếu có lỗi

# ==========================================
# 1. CẤU HÌNH TOKEN
# ==========================================
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="buivancong012@gmail.com"
PASS_UR="buivancong012"
KEY_ANTGAIN="ud0F9rj2KgAXWgJ20Dw6sogFOjJvytLyVSGtQUrfo4QJq3LAAvdh8XF5jUERcIeU"

# ==========================================
# 2. CẤU HÌNH IMAGE
# ==========================================
IMG_TM="traffmonetizer/cli_v2:latest"
IMG_REPOCKET="repocket/repocket:latest"
IMG_MYST="mysteriumnetwork/myst:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_ANT="pinors/antgain-cli:latest"

log() { echo -e "\e[32m[INFO] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==========================================
# 3. CÀI ĐẶT & DỌN DẸP
# ==========================================
log "Gỡ bỏ phần mềm cũ..."
timeout 60 sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
fi

log "Dọn dẹp container & network cũ..."
if [ -n "$(docker ps -aq)" ]; then docker rm -f $(docker ps -aq) >/dev/null 2>&1; fi
docker network prune -f >/dev/null 2>&1

# ==========================================
# 4. TẠO NETWORK
# ==========================================
log "Tạo Docker Networks..."
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 >/dev/null 2>&1 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 >/dev/null 2>&1 || true

# ==========================================
# 5. LẤY IP (GIỮ NGUYÊN CƠ CHẾ CỦA BẠN)
# ==========================================
log "Đang lấy IP từ eth0..."
IP_ALLA=$(ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^10\.')
IP_ALLB=$(ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '^10\.')

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then
  err "Không lấy được IP eth0 (A=$IP_ALLA, B=$IP_ALLB). Kiểm tra lại interface."
fi
log "IP Detected: A=$IP_ALLA | B=$IP_ALLB"

# ==========================================
# 6. CẤU HÌNH IPTABLES (SNAT)
# ==========================================
log "Cấu hình iptables SNAT..."
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

log "⏳ Đợi 10 giây cho iptables ổn định..."
sleep 10

# ==========================================
# 7. CHECK IP PUBLIC THỰC TẾ (QUAN TRỌNG)
# ==========================================
get_public_ip() {
    local NET=$1
    # Dùng image curl siêu nhẹ để check IP
    docker run --rm --network "$NET" curlimages/curl:latest -s --max-time 10 https://api.ipify.org
}

log "🕵️ Đang kiểm tra IP Public thực tế..."

# Check lần lượt 2 mạng
PUB_IP_1=$(get_public_ip "my_network_1")
PUB_IP_2=$(get_public_ip "my_network_2")

log "👉 Kết quả Check:"
log "   Network 1 (Gốc: $IP_ALLA) -> Ra ngoài bằng: [$PUB_IP_1]"
log "   Network 2 (Gốc: $IP_ALLB) -> Ra ngoài bằng: [$PUB_IP_2]"

# KIỂM TRA ĐIỀU KIỆN
if [ -z "$PUB_IP_1" ] || [ -z "$PUB_IP_2" ]; then
    err "❌ LỖI: Không lấy được IP Public (Mất mạng hoặc lỗi Docker)."
fi

if [ "$PUB_IP_1" == "$PUB_IP_2" ]; then
    err "❌ LỖI TRÙNG IP: Cả 2 mạng đều ra cùng 1 IP Public ($PUB_IP_1). DỪNG SCRIPT!"
else
    log "✅ THÀNH CÔNG: Hai mạng đã nhận diện 2 IP Public KHÁC NHAU."
fi

# ==========================================
# 8. CHẠY CONTAINER
# ==========================================
log "Đang Pull images (Song song)..."
docker pull $IMG_TM >/dev/null 2>&1 &
docker pull $IMG_REPOCKET >/dev/null 2>&1 &
docker pull $IMG_MYST >/dev/null 2>&1 &
docker pull $IMG_EARN >/dev/null 2>&1 &
docker pull $IMG_UR >/dev/null 2>&1 &
docker pull $IMG_ANT >/dev/null 2>&1 &
wait 
log "Pull hoàn tất."

run_node_group() {
  local ID=$1; local NET="my_network_$1"; local BIND_IP=$2
  log "🚀 Khởi chạy nhóm $ID..."

  # Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $IMG_TM start accept --token "$TOKEN_TM" >/dev/null
  # Repocket
  docker run -d --network $NET --restart always --name repocket$ID -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPOCKET >/dev/null
  # Mysterium (Bind IP)
  docker run -d --network $NET --cap-add NET_ADMIN -p ${BIND_IP}:4449:4449 --name myst$ID -v myst-data$ID:/var/lib/mysterium-node --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null
  # EarnFM
  docker run -d --network $NET --restart always -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$ID $IMG_EARN >/dev/null
  # UrNetwork
  docker run -d --network $NET --restart always --cap-add NET_ADMIN --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null
  # AntGain
  docker run -d --network $NET --restart always --name antgain$ID -e ANTGAIN_API_KEY="$KEY_ANTGAIN" $IMG_ANT >/dev/null
}

run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

log "==== CÀI ĐẶT THÀNH CÔNG ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
