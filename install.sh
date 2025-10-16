#!/bin/bash
set -euo pipefail

# ===================== CONFIG CỨNG =====================
TOKEN='/PfkwR8qQMfbsCMrSaaDhsX96E9w2PeHH2bcGeyFBno='
EARNFM_TOKEN='50f04bbe-94d9-4f6a-82b9-b40016bd4bbb'
UR_USER='nguyenvinhcao123@gmail.com'
UR_PASS='CAOcao123CAO@'

# Tùy chọn
UR_ENABLE_IP_CHECKER=false
UR_PROXY_FILE=""        # nếu có proxy.txt thì điền đường dẫn tuyệt đối vào đây
MYST_PORT=4449

# Tùy chọn dọn sạch Docker trước khi khởi tạo
PURGE_CONTAINERS=true
PURGE_IMAGES=true
PURGE_NETWORKS=true

# Mạng nội bộ cho các container
NET1_NAME="my_network_1"
NET2_NAME="my_network_2"
NET1_CIDR="192.168.33.0/24"
NET2_CIDR="192.168.34.0/24"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ===================== Chọn image theo kiến trúc =====================
arch="$(uname -m)"
case "$arch" in
  aarch64|arm64) TM_IMAGE="traffmonetizer/cli_v2:arm64v8" ;;
  x86_64|amd64)  TM_IMAGE="traffmonetizer/cli_v2:latest"  ;;
  *)             TM_IMAGE="traffmonetizer/cli_v2:latest"  ;;
esac

# UR image
UR_IMAGE_AMD64="ghcr.io/techroy23/docker-urnetwork:latest"
UR_IMAGE_ARM64="techroy23/docker-urnetwork:latest"
if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
  UR_PLATFORM="--platform linux/arm64"
  UR_IMAGE="$UR_IMAGE_ARM64"
else
  UR_PLATFORM="--platform linux/amd64"
  UR_IMAGE="$UR_IMAGE_AMD64"
fi

# ===================== Cài Docker nếu thiếu =====================
install_pkgs() {
  if need_cmd yum; then
    sudo yum -y update || true
    sudo yum -y install "$@" || true
  elif need_cmd dnf; then
    sudo dnf -y update || true
    sudo dnf -y install "$@" || true
  elif need_cmd apt-get; then
    sudo apt-get update -y || true
    sudo apt-get install -y "$@" || true
  else
    return 1
  fi
}

if ! need_cmd docker; then
  echo "[INFO] Docker chưa có -> cài đặt..."
  install_pkgs docker docker.io || true
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "[INFO] Docker đã cài và khởi động. Chạy lại script lần nữa."
  exit 0
fi

# ===================== Dọn Docker =====================
if [[ "$PURGE_CONTAINERS" == "true" ]] && [[ "$(docker ps -aq | wc -l)" -gt 0 ]]; then
  echo "[WARN] Xoá toàn bộ containers..."
  docker rm -f $(docker ps -aq) || true
fi
if [[ "$PURGE_IMAGES" == "true" ]] && [[ "$(docker images -q | wc -l)" -gt 0 ]]; then
  echo "[WARN] Xoá toàn bộ images..."
  docker rmi -f $(docker images -q) || true
fi
if [[ "$PURGE_NETWORKS" == "true" ]]; then
  echo "[INFO] Xoá networks cũ..."
  while read -r net; do
    [[ -n "$net" ]] && docker network rm "$net" || true
  done < <(docker network ls --format '{{.Name}}' | grep -vE '^(bridge|host|none)$' || true)
fi

# ===================== Tạo networks =====================
docker network create "${NET1_NAME}" --driver bridge --subnet "${NET1_CIDR}" >/dev/null 2>&1 || true
docker network create "${NET2_NAME}" --driver bridge --subnet "${NET2_CIDR}" >/dev/null 2>&1 || true

# ===================== Phát hiện interface & IP =====================
DEV="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
IP1="$(ip -4 addr show dev "$DEV" | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
IP2="$(ip -4 addr show dev "$DEV" | awk '/inet /{print $2}' | sed -n '2p' | cut -d/ -f1)"
[[ -z "${IP2:-}" ]] && IP2="$IP1"
echo "[INFO] DEV=$DEV | IP1=$IP1 | IP2=$IP2"

# ===================== Bật IP forward =====================
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null || true
sudo sysctl --system >/dev/null || true

# ===================== iptables SNAT =====================
if ! need_cmd iptables; then
  install_pkgs iptables iptables-services || install_pkgs iptables-nft || true
fi

del_snat() {
  local CIDR="$1"
  for TOIP in "$IP1" "$IP2"; do
    while sudo iptables -t nat -C POSTROUTING -s "$CIDR" -o "$DEV" -j SNAT --to-source "$TOIP" 2>/dev/null; do
      sudo iptables -t nat -D POSTROUTING -s "$CIDR" -o "$DEV" -j SNAT --to-source "$TOIP" || true
    done
  done
}
add_snat() {
  local CIDR="$1" TOIP="$2"
  if ! sudo iptables -t nat -C POSTROUTING -s "$CIDR" -o "$DEV" -j SNAT --to-source "$TOIP" 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -s "$CIDR" -o "$DEV" -j SNAT --to-source "$TOIP"
  fi
}

echo "[INFO] Áp SNAT..."
del_snat "$NET1_CIDR"; del_snat "$NET2_CIDR"
add_snat "$NET1_CIDR" "$IP1"
add_snat "$NET2_CIDR" "$IP2"

# ===================== Pull images =====================
echo "[INFO] Pull images..."
docker pull "${TM_IMAGE}" || true
docker pull mysteriumnetwork/myst:latest || true
docker pull earnfm/earnfm-client:latest || true
docker pull "$UR_IMAGE" || true

# ===================== Run Traffmonetizer =====================
echo "[INFO] Run Traffmonetizer..."
docker run -d --network "${NET1_NAME}" --restart always --name tm1 "${TM_IMAGE}" start accept --token "${TOKEN}"
docker run -d --network "${NET2_NAME}" --restart always --name tm2 "${TM_IMAGE}" start accept --token "${TOKEN}"

# ===================== Run Myst =====================
echo "[INFO] Run Myst..."
docker run -d --network "${NET1_NAME}" --cap-add NET_ADMIN \
  -p "${IP1}:${MYST_PORT}:${MYST_PORT}" \
  --name myst1 -v myst-data1:/var/lib/mysterium-node \
  --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

docker run -d --network "${NET2_NAME}" --cap-add NET_ADMIN \
  -p "${IP2}:${MYST_PORT}:${MYST_PORT}" \
  --name myst2 -v myst-data2:/var/lib/mysterium-node \
  --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# ===================== Run EarnFM =====================
echo "[INFO] Run EarnFM..."
docker run -d --network "${NET1_NAME}" --restart=always -e EARNFM_TOKEN="${EARNFM_TOKEN}" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network "${NET2_NAME}" --restart=always -e EARNFM_TOKEN="${EARNFM_TOKEN}" --name earnfm2 earnfm/earnfm-client:latest

# ===================== Run URNetwork =====================
echo "[INFO] Run URNetwork..."
UR_VOL1="vnstat_data_ur1"
UR_VOL2="vnstat_data_ur2"
docker volume create "$UR_VOL1" >/dev/null 2>&1 || true
docker volume create "$UR_VOL2" >/dev/null 2>&1 || true

UR_PROXY_MOUNT=()
if [[ -n "$UR_PROXY_FILE" && -f "$UR_PROXY_FILE" ]]; then
  UR_PROXY_MOUNT=( -v "$UR_PROXY_FILE:/app/proxy.txt" )
fi

# ur1
docker run -d $UR_PLATFORM \
  --name "ur1" \
  --network "${NET1_NAME}" \
  --restart "always" \
  --pull "always" \
  --privileged \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=3 \
  -e USER_AUTH="${UR_USER}" \
  -e PASSWORD="${UR_PASS}" \
  -e ENABLE_IP_CHECKER="${UR_ENABLE_IP_CHECKER}" \
  -v "${UR_VOL1}:/var/lib/vnstat" \
  "${UR_PROXY_MOUNT[@]}" \
  "$UR_IMAGE"

# ur2
docker run -d $UR_PLATFORM \
  --name "ur2" \
  --network "${NET2_NAME}" \
  --restart "always" \
  --pull "always" \
  --privileged \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=3 \
  -e USER_AUTH="${UR_USER}" \
  -e PASSWORD="${UR_PASS}" \
  -e ENABLE_IP_CHECKER="${UR_ENABLE_IP_CHECKER}" \
  -v "${UR_VOL2}:/var/lib/vnstat" \
  "${UR_PROXY_MOUNT[@]}" \
  "$UR_IMAGE"

# ===================== Summary =====================
echo ""
echo "================= DONE ================="
echo "Interface: $DEV"
echo "IP1: $IP1 (SNAT ${NET1_CIDR}, Myst:${MYST_PORT})"
echo "IP2: $IP2 (SNAT ${NET2_CIDR}, Myst:${MYST_PORT})"
echo "Containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "========================================"
