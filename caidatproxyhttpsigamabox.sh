#!/bin/bash
set -Eeuo pipefail

# ======== GUARD: bắt buộc chạy bằng bash =========
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[ERR] Script này yêu cầu bash. Hãy chạy bằng: bash $0 [up|status|down]"
  exit 1
fi

# ===================== CONFIG =====================
# Upstream HTTP proxy mỗi tuyến. Hỗ trợ 2 định dạng:
#  1) http://user:pass@host:port
#  2) host:port:user:pass
UPSTREAMS=(
"http://user27474:1758906804@s11.pxus.live:27474"
"http://user20538:1758177032@103.82.25.199:20538"
"http://user55448:1759308326@s13.pxus.live:55448"
"http://user24640:1758163571@s3.pxus.live:24640"
"http://user50907:1758123031@103.82.27.148:50907"
"http://user21772:1759114887@s13.pxus.live:21772"
"http://user38506:1758123016@103.82.26.78:38506"
"http://user14937:1758177032@s15.pxus.live:14937"
"http://user37318:1758265252@103.82.25.199:37318"
"http://user56076:1758740726@103.82.27.99:56076"
"http://user10206:1757935434@103.82.27.99:10206"
"http://user23231:1758163586@103.82.26.78:23231"
"http://user19027:1758072607@103.82.27.99:19027"
"http://user19362:1757589629@103.82.27.99:19362"
"http://user33846:1759040239@s13.pxus.live:33846"
"http://user17626:1757589614@103.82.27.99:17626"
"http://user13751:1757735104@103.82.27.99:13751"
"http://user12454:1757545219@103.82.27.99:12454"
"http://user23315:1758177017@s15.pxus.live:23315"
"http://user27592:1758260705@s15.pxus.live:27592"
"http://user22523:1758072607@103.82.27.99:22523"
"http://user18595:1757898998@103.82.27.148:18595"
"http://user13053:1759408219@s13.pxus.live:13053"
"http://user23645:1758177032@103.82.25.199:23645"
"http://user22340:1757689237@103.82.27.99:22340"
"http://user21035:1757689237@103.82.27.99:21035"
"http://user54491:1758123031@s2.pxus.live:54491"
"http://user17430:1757689237@103.82.27.99:17430"
"http://user29246:1758177032@103.82.25.199:29246"
"http://user38507:1757303440@103.82.26.78:38507"
"http://user38953:1758518106@s13.pxus.live:38953"
"http://user30302:1759040194@s13.pxus.live:30302"
"http://user28690:1758955655@s13.pxus.live:28690"
"http://user11987:1758247210@103.82.25.199:11987"
"http://user26235:1758189488@103.82.25.199:26235"
"http://user10048:1758955640@s13.pxus.live:10048"
"http://user25246:1757735104@103.82.27.99:25246"
"http://user15594:1757545249@103.82.27.99:15594"
"http://user27530:1758247210@s15.pxus.live:27530"
"http://user13047:1757735104@103.82.27.99:13047"
"http://user41783:1758433506@s3.pxus.live:41783"
"http://user19280:1758907059@103.82.25.188:19280"
"http://user12618:1757863866@103.82.27.148:12618"
"http://user12293:1758259144@s13.pxus.live:12293"
"http://user52671:1759227327@s13.pxus.live:52671"
"http://user36444:1758179749@103.82.25.199:36444"
"http://user41379:1759308326@s13.pxus.live:41379"
"http://user12651:1758163616@103.82.26.78:12651"
"http://user24450:1758072607@103.82.27.99:24450"
"http://user44368:1759114857@s13.pxus.live:44368"
"http://user49032:1758360642@s3.pxus.live:49032"
"http://user17260:1758068104@103.82.27.99:17260"
"http://user19661:1758907029@s11.pxus.live:19661"
"http://user20858:1757735104@103.82.27.99:20858"
"http://user19045:1758072607@103.82.27.99:19045"

)

SBOX_NAME_BASE="sbox"
DOH_NAME_BASE="doh"

IMG_SBOX="ghcr.io/sagernet/sing-box:latest"
IMG_DOH="cloudflare/cloudflared:latest"

SBOX_LOGLEVEL="${SBOX_LOGLEVEL:-warn}"   # trace|debug|info|warn|error
SBOX_MTU="${SBOX_MTU:-1400}"
USE_TEST_IMAGE="${USE_TEST_IMAGE:-false}"

ENABLE_BBR="${ENABLE_BBR:-true}"
ENABLE_TFO="${ENABLE_TFO:-true}"

# ===================== PRECHECK =====================
command -v docker >/dev/null 2>&1 || { echo "[ERR] Cần Docker."; exit 1; }

if [[ ! -e /dev/net/tun ]]; then
  echo "[INFO] Tạo /dev/net/tun..."
  sudo mkdir -p /dev/net || true
  sudo mknod /dev/net/tun c 10 200 || true
  sudo chmod 666 /dev/net/tun || true
fi

optimize_sysctl() {
  if [[ "$ENABLE_BBR" == "true" ]]; then
    sudo sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  fi
  if [[ "$ENABLE_TFO" == "true" ]]; then
    sudo sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
  fi
}

# ===================== FUNCS =====================

# Trả "host port user pass" từ:
#  - http://user:pass@host:port
#  - host:port:user:pass
parse_upstream_any() {
  local u="$1"
  if [[ "$u" =~ ^https?:// ]]; then
    local tmp="${u#http://}"; tmp="${tmp#https://}"
    local creds="${tmp%@*}"
    local hostport="${tmp#*@}"
    local user="${creds%%:*}"
    local pass="${creds#*:}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"
    echo "$host" "$port" "$user" "$pass"
  else
    local host port user pass
    IFS=':' read -r host port user pass <<<"$u"
    echo "$host" "$port" "$user" "$pass"
  fi
}

cleanup_route() {
  local idx="$1"
  local s="${SBOX_NAME_BASE}${idx}"
  local d="${DOH_NAME_BASE}${idx}"
  docker rm -f "$d" "$s" >/dev/null 2>&1 || true
  rm -f "resolv_${idx}.conf" "sbox_${idx}.json" >/dev/null 2>&1 || true
}

mk_sbox_config() {
  # $1: file, $2: ip, $3: port, $4: user, $5: pass
  local cfg="$1" ip="$2" port="$3" user="$4" pass="$5"
  cat > "$cfg" <<JSON
{
  "log": { "level": "${SBOX_LOGLEVEL}" },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "doh-local",
        "server": "127.0.0.1",
        "server_port": 53,
        "strategy": "ipv4_only"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "strict_route": false,
      "sniff": true,
      "mtu": ${SBOX_MTU}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "type": "http",
      "server": "${ip}",
      "server_port": ${port},
      "username": "${user}",
      "password": "${pass}"
    },
    { "tag": "direct", "type": "direct" }
  ],
  "route": {
    "default_domain_resolver": "doh-local",
    "auto_detect_interface": true,
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
    ],
    "final": "proxy"
  }
}
JSON
}

check_sbox_config() {
  docker run --rm --cap-add=NET_ADMIN --device /dev/net/tun \
    -v "$PWD/$1":/etc/sing-box/config.json:ro \
    "$IMG_SBOX" check -c /etc/sing-box/config.json
}

start_route() {
  local idx="$1" upstream="$2"
  local s="${SBOX_NAME_BASE}${idx}"
  local d="${DOH_NAME_BASE}${idx}"
  local cfg="sbox_${idx}.json"
  local resolv_file="resolv_${idx}.conf"

  echo "------------------------------------------------------------"
  echo "[ROUTE $idx] Upstream: $upstream"

  cleanup_route "$idx"

  read -r ip port user pass <<<"$(parse_upstream_any "$upstream")"
  if [[ -z "$ip" || -z "$port" || -z "$user" || -z "$pass" ]]; then
    echo "[ERR] Upstream không hợp lệ: $upstream"
    return 0
  fi

  printf "options ndots:0\nnameserver 127.0.0.1\n" > "$resolv_file"

  mk_sbox_config "$cfg" "$ip" "$port" "$user" "$pass"
  if ! check_sbox_config "$cfg"; then
    echo "[ERR] Config sing-box route $idx không hợp lệ."
    return 0
  fi

  docker run -d --name "$s" --restart=always \
    --cap-add=NET_ADMIN --device /dev/net/tun \
    -v "$PWD/$cfg":/etc/sing-box/config.json:ro \
    -v "$PWD/$resolv_file":/etc/resolv.conf:ro \
    "$IMG_SBOX" run -c /etc/sing-box/config.json >/dev/null

  docker run -d --name "$d" --restart=always \
    --network=container:"$s" \
    "$IMG_DOH" proxy-dns \
      --address 127.0.0.1 \
      --port 53 \
      --upstream https://1.1.1.1/dns-query \
      --upstream https://1.0.0.1/dns-query >/dev/null

  if [[ "$USE_TEST_IMAGE" == "true" ]]; then
    docker run --rm --network=container:"$s" curlimages/curl:latest -s https://ifconfig.me || true
    echo
  else
    echo "[ROUTE $idx] RUNNING (bỏ qua test)"
  fi

  echo "→ Gắn app: docker run ... --network=container:${s} <image> ..."
}

down_all() {
  echo "[CLEANUP] Xoá toàn bộ tuyến..."
  local i=1
  for _ in "${UPSTREAMS[@]}"; do
    cleanup_route "$i"
    ((i++))
  done
  echo "[DONE]"
}

status_all() {
  local i=1
  for _ in "${UPSTREAMS[@]}"; do
    local s="${SBOX_NAME_BASE}${i}"
    if docker ps --format '{{.Names}}' | grep -qx "$s"; then
      echo "[STATUS] $s: running"
    else
      echo "[STATUS] $s: not running"
    fi
    ((i++))
  done
}

# ===================== CLI =====================
case "${1:-up}" in
  up)
    optimize_sysctl
    i=1
    for uri in "${UPSTREAMS[@]}"; do
      start_route "$i" "$uri"
      ((i++))
    done
    echo
    echo "✅ ĐÃ KHỞI TẠO ${#UPSTREAMS[@]} TUYẾN (sing-box TUN + cloudflared DoH)."
    echo "ℹ️  Chỉ container gắn --network=container:sboxN mới đi qua tuyến tương ứng."
    ;;
  status) status_all ;;
  down)   down_all ;;
  *)
    echo "Usage: $0 [up|status|down]"
    exit 1
    ;;
esac
