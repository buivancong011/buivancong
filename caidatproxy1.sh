#!/usr/bin/env bash
set -Eeuo pipefail

# ======= CẤU HÌNH CHÍNH =======
IMG="ghcr.io/sagernet/sing-box:latest"
NAME_BASE="sbox"                # sbox1, sbox2, ...
WORKDIR="${PWD}"
TUN_SUBNET_PREFIX="172.30"      # mỗi route: 172.30.<N>.1/30
STACK="system"                  # hoặc "gvisor" nếu host khó tính

# (Tùy chọn) Giới hạn số route khởi chạy (0 = chạy hết trong danh sách)
LIMIT_ROUTES=0

# --- Danh sách proxy dạng: IP:PORT:USER:PASS (port của bạn: 1339) ---
#   Bạn có thể dán toàn bộ list vào đây. Mình để lại 10 dòng mẫu đầu;
#   phần còn lại chỉ cần nối thêm vào khối PROXY_RAW bên dưới.
read -r -d '' PROXY_RAW <<'EOF'
156.239.204.25:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.201.49:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.202.151:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.201.0:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.196.11:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.203.251:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.205.107:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.198.52:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.195.73:1339:cao_nAEfN2:g2Bawi4kkDZyztX
156.239.197.103:1339:cao_nAEfN2:g2Bawi4kkDZyztX
# ===> Dán tiếp các dòng IP:1339:USER:PASS của bạn vào đây <===
EOF

# ======= HÀM PHỤ =======
err() { echo "[ERR] $*" >&2; }
info() { echo "$*"; }

need_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Cần Docker. Cài Docker rồi chạy lại."
    exit 1
  fi
}

ensure_tun() {
  if [[ ! -e /dev/net/tun ]]; then
    info "[INFO] Tạo /dev/net/tun..."
    sudo mkdir -p /dev/net || true
    sudo mknod /dev/net/tun c 10 200 || true
    sudo chmod 666 /dev/net/tun || true
  fi
}

# Chuyển PROXY_RAW thành mảng 4 trường (ip port user pass)
parse_proxies() {
  mapfile -t PROXIES < <(printf '%s\n' "$PROXY_RAW" | sed '/^\s*#/d;/^\s*$/d')
  if ((${#PROXIES[@]}==0)); then
    err "Danh sách proxy rỗng."
    exit 1
  fi
}

json_escape() { jq -Rr @json <<<"$1"; }

make_config() {
  local idx="$1" ip="$2" port="$3" user="$4" pass="$5"
  local tun_octet="${idx}"
  if ((tun_octet>250)); then tun_octet=$((tun_octet%250+1)); fi
  local tun_cidr="${TUN_SUBNET_PREFIX}.${tun_octet}.1/30"

  # Cấu hình mới (KHÔNG legacy): dùng "address": [ "CIDR" ]
  cat <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun",
      "stack": ${STACK@Q},
      "auto_route": true,
      "strict_route": true,
      "address": [ ${$(json_escape "$tun_cidr")} ]
    }
  ],
  "dns": {
    "servers": [
      { "address": "tls://1.1.1.1", "detour": "proxy", "strategy": "ipv4_only" },
      { "address": "tls://8.8.8.8", "detour": "proxy", "strategy": "ipv4_only" }
    ],
    "strategy": "ipv4_only",
    "independent_cache": true
  },
  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": ${$(json_escape "$ip")},
      "server_port": $port,
      "username": ${$(json_escape "$user")},
      "password": ${$(json_escape "$pass")},
      "udp_over_tcp": { "enabled": false }
    },
    { "type": "direct", "tag": "DIRECT" },
    { "type": "block",  "tag": "BLOCK" }
  ],
  "route": {
    "final": "proxy",
    "auto_detect_interface": true
  }
}
JSON
}

cleanup_one() {
  local name="$1"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

wait_running() {
  local name="$1" tries=20
  while ((tries--)); do
    local st
    st="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    if [[ "$st" == "running" ]]; then return 0; fi
    sleep 0.5
  done
  return 1
}

test_latency_ip() {
  # Test qua địa chỉ IP (không phụ thuộc DNS của app)
  local name="$1"
  docker run --rm --network=container:"$name" \
    curlimages/curl -s -o /dev/null \
    -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    https://1.1.1.1 || return 1
}

start_one() {
  local idx="$1" line="$2"
  IFS=':' read -r ip port user pass <<<"$line"
  local name="${NAME_BASE}${idx}"
  local cfg="${WORKDIR}/${name}.json"

  info "------------------------------------------------------------"
  info "[ROUTE $idx] SOCKS5: ${user}:${pass}@${ip}:${port}"

  cleanup_one "$name"
  make_config "$idx" "$ip" "$port" "$user" "$pass" > "$cfg"

  # (Tùy chọn) kiểm tra cấu hình trước khi chạy
  if ! docker run --rm \
      --cap-add=NET_ADMIN --device /dev/net/tun \
      -v "$cfg:/etc/sing-box/config.json:ro" \
      "$IMG" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
    err "[ROUTE $idx] Cấu hình lỗi (check failed)."
    return 1
  fi

  # Run container
  docker run -d --name "$name" \
    --cap-add=NET_ADMIN --device /dev/net/tun \
    -v "$cfg:/etc/sing-box/config.json:ro" \
    --restart=always "$IMG" \
    run -c /etc/sing-box/config.json >/dev/null

  # Chờ container lên trạng thái running để tránh lỗi join netns
  if ! wait_running "$name"; then
    err "[ROUTE $idx] Container không vào trạng thái running (đang restarting?)."
    info "[ROUTE $idx] Gợi ý: docker logs $name ; docker inspect $name --format '{{json .State}}'"
    return 1
  fi

  # Đo latency qua IP
  printf "[ROUTE %s] latency(IP): " "$idx"
  if ! test_latency_ip "$name"; then
    echo "FAIL"
    info "[ROUTE $idx] Gợi ý: docker logs $name ; docker inspect $name --format '{{json .State}}'"
  fi

  info "[ROUTE $idx] RUNNING: $name"
  info "→ App SOCKS5H (DNS tại proxy):  curl --socks5-hostname USER:PASS@IP:PORT https://..."
  info "→ App chia sẻ netns:           docker run ... --network=container:$name <image> ..."
}

start_all() {
  need_docker
  ensure_tun
  parse_proxies

  local total="${#PROXIES[@]}"
  if ((LIMIT_ROUTES>0 && LIMIT_ROUTES<total)); then total="$LIMIT_ROUTES"; fi

  for ((i=1;i<=total;i++)); do
    start_one "$i" "${PROXIES[i-1]}" || true
  done

  echo
  info "✅ ĐÃ KHỞI TẠO ${total} ROUTES (sing-box, DNS qua proxy)."
  info "👉 Gắn app:  docker run ... --network=container:${NAME_BASE}N <image> ..."
  info "👉 App CLI SOCKS5H:  curl --socks5-hostname USER:PASS@IP:PORT https://..."
}

down_all() {
  need_docker
  for n in $(docker ps -a --format '{{.Names}}' | grep "^${NAME_BASE}" || true); do
    cleanup_one "$n"
  done
  rm -f "${WORKDIR}/${NAME_BASE}"*.json 2>/dev/null || true
  info "[DONE] Đã xoá toàn bộ routes & file cấu hình."
}

status_all() {
  need_docker
  local names
  names=$(docker ps --format '{{.Names}}' | grep "^${NAME_BASE}" || true)
  if [[ -z "$names" ]]; then
    info "Không có container ${NAME_BASE}* đang chạy."
    return 0
  fi
  for n in $names; do
    printf "[STATUS] %-8s " "$n"
    docker run --rm --network=container:"$n" curlimages/curl -s https://1.1.1.1/cdn-cgi/trace \
      | grep '^ip=' | cut -d= -f2 || echo "N/A"
  done
}

case "${1:-up}" in
  up)     start_all ;;
  down)   down_all  ;;
  status) status_all ;;
  *)
    echo "Usage: $0 [up|down|status]"
    exit 1
    ;;
esac
