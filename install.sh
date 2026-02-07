#!/bin/bash
set -e

# ==== CẤU HÌNH TOKEN & IMAGE ====
# Thay đổi token tại đây để dễ quản lý
TOKEN_TM="/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno="
TOKEN_EARNFM="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
TOKEN_REPOCKET_EMAIL="nguyenvinhson000@gmail.com"
TOKEN_REPOCKET_API="cad6dcce-d038-4727-969b-d996ed80d3ef"
USER_UR="testphuong123@gmail.com"
PASS_UR="CAOcao123456789"

# Danh sách Image
IMG_TM="traffmonetizer/cli_v2:arm64v8" # Lưu ý: Chỉ chạy trên chip ARM (Graviton)
IMG_MYST="mysteriumnetwork/myst:latest"
IMG_UR="techroy23/docker-urnetwork:latest"
IMG_EARN="earnfm/earnfm-client:latest"
IMG_REPO="repocket/repocket:latest"

# ==== HÀM TIỆN ÍCH ====
log() { echo -e "\e[32m[INFO] $1\e[0m"; }
warn() { echo -e "\e[33m[WARN] $1\e[0m"; }
err() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# ==== 1. CHUẨN BỊ HỆ THỐNG ====
log "Dọn dẹp Squid & Httpd..."
sudo yum remove -y squid httpd-tools >/dev/null 2>&1 || true

if ! command -v docker &> /dev/null; then
  log "Cài đặt Docker..."
  sudo yum update -y -q
  sudo yum install -y -q docker
  sudo systemctl enable --now docker
else
  log "Docker đã được cài đặt."
fi

# ==== 2. LẤY IP (GIỮ NGUYÊN LOGIC CŨ) ====
# Lưu ý: Interface ens5 là hardcode theo script cũ của bạn
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

if [ -z "$IP_ALLA" ] || [ -z "$IP_ALLB" ]; then
  err "Không lấy được IP trên interface ens5. Kiểm tra lại server!"
fi
log "IP detected: A=$IP_ALLA | B=$IP_ALLB"

# ==== 3. DỌN DẸP DOCKER CŨ ====
log "Dọn dẹp Containers, Networks & Images cũ..."
# Xóa tất cả container đang chạy hoặc đã tắt
if [ -n "$(docker ps -aq)" ]; then
  docker rm -f $(docker ps -aq) >/dev/null 2>&1
fi
# Prune hệ thống cho sạch (Network + Volume dangling)
docker system prune -f >/dev/null 2>&1 || true

# Xóa network custom (giữ lại bridge/host/none)
docker network prune -f >/dev/null 2>&1

# ==== 4. TẠO NETWORK ====
log "Tạo Docker Networks..."
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 >/dev/null
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 >/dev/null

# ==== 5. CẤU HÌNH IPTABLES (SNAT) ====
log "Thiết lập IPTables SNAT..."

# Xóa rule cũ và thêm rule mới (như cũ)
sudo iptables -t nat -D POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}
sudo iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

# 👉 [THÊM MỚI] CƠ CHẾ CHỜ VÀ KIỂM TRA MẠNG 👈
log "⏳ Đợi 10 giây để Network Stack và Iptables ổn định..."
sleep 10

log "🔍 Kiểm tra kết nối thực tế qua IP nguồn..."

# Hàm check IP ra internet (Curl qua interface cụ thể)
check_connection() {
  local CHECK_IP=$1
  # Thử curl đến google hoặc ifconfig.me qua interface IP đó
  # --interface: bắt buộc curl đi qua IP này
  # --max-time 5: nếu 5s không được thì báo lỗi
  if curl -s --interface "$CHECK_IP" --max-time 5 https://ifconfig.me > /dev/null; then
      log "✅ IP $CHECK_IP: Kết nối Internet OK."
  else
      err "❌ IP $CHECK_IP: Không thể kết nối Internet! Kiểm tra lại iptables hoặc Interface."
  fi
}

# Kiểm tra cả 2 IP trước khi chạy container
check_connection "$IP_ALLA"
check_connection "$IP_ALLB"

# ==== 6. PULL IMAGES (CHẠY SONG SONG) ====
log "Pulling images..."
pids=""
for img in "$IMG_TM" "$IMG_MYST" "$IMG_UR" "$IMG_EARN" "$IMG_REPO"; do
  docker pull $img >/dev/null 2>&1 &
  pids="$pids $!"
done
wait $pids # Đợi tất cả pull xong mới chạy tiếp
log "Pull images hoàn tất."

# ==== 7. CHẠY CONTAINERS (VÒNG LẶP) ====
# Hàm chạy node để tránh lặp code
run_node_group() {
  local ID=$1
  local NET="my_network_$1"
  local IP_BIND=$2
  
  log "Đang khởi tạo Node $ID trên mạng $NET ($IP_BIND)..."

  # 1. Traffmonetizer
  docker run -d --network $NET --restart always --name tm$ID $IMG_TM start accept --token "$TOKEN_TM" >/dev/null

  # 2. Mysterium (Cần bind port IP cụ thể)
  # Lưu ý: Mysterium cần volume riêng biệt cho mỗi node
  docker run -d --network $NET --cap-add NET_ADMIN -p ${IP_BIND}:4449:4449 \
    --name myst$ID -v myst-data$ID:/var/lib/mysterium-node \
    --restart unless-stopped $IMG_MYST service --agreed-terms-and-conditions >/dev/null

  # 3. UrNetwork
  docker run -d --network $NET --restart always --cap-add NET_ADMIN \
    --name urnetwork$ID -v ur_data$ID:/var/lib/vnstat \
    -e USER_AUTH="$USER_UR" -e PASSWORD="$PASS_UR" $IMG_UR >/dev/null

  # 4. EarnFM
  docker run -d --network $NET --restart always \
    -e EARNFM_TOKEN="$TOKEN_EARNFM" --name earnfm$ID $IMG_EARN >/dev/null

  # 5. Repocket
  docker run -d --network $NET --restart always \
    --name repocket$ID -e RP_EMAIL="$TOKEN_REPOCKET_EMAIL" \
    -e RP_API_KEY="$TOKEN_REPOCKET_API" $IMG_REPO >/dev/null
}

# Gọi hàm chạy cho 2 luồng
run_node_group 1 "$IP_ALLA"
run_node_group 2 "$IP_ALLB"

log "==== HOÀN TẤT CÀI ĐẶT ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
