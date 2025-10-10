cat > sbox_multi.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# ====== DANH SÁCH PROXY (SOCKS5) ======
# Định dạng: user:pass@ip:port
PROXIES=(
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.204.25:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.201.49:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.202.151:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.201.0:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.196.11:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.203.251:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.205.107:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.198.52:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.195.73:1339"
"cao_nAEfN2:g2Bawi4kkDZyztX@156.239.197.103:1339"
)

IMG="ghcr.io/sagernet/sing-box:latest"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERR] Thiếu $1"; exit 1; }; }
need docker

# Tạo /dev/net/tun nếu thiếu
if [[ ! -e /dev/net/tun ]]; then
  sudo mkdir -p /dev/net || true
  sudo mknod /dev/net/tun c 10 200 || true
  sudo chmod 666 /dev/net/tun || true
fi

make_cfg() {
  local idx="$1"
  local auth_host_port="$2"   # user:pass@ip:port
  local user="${auth_host_port%%:*}"
  local pass_host_port="${auth_host_port#*:}"
  local pass="${pass_host_port%%@*}"
  local host_port="${pass_host_port#*@}"
  local host="${host_port%%:*}"
  local port="${host_port##*:}"
  local ip4="172.30.$((idx)).1/30"

  cat > "sbox_${idx}.json" <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun",
      "address": ["${ip4}"],
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": false
    }
  ],
  "dns": {
    "servers": [
      { "server": "tls://1.1.1.1", "detour": "proxy", "strategy": "ipv4_only" },
      { "server": "tls://8.8.8.8", "detour": "proxy", "strategy": "ipv4_only" }
    ],
    "strategy": "ipv4_only",
    "independent_cache": true
  },
  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": "${host}",
      "server_port": ${port},
      "username": "${user}",
      "password": "${pass}",
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

up_one() {
  local idx="$1"
  local auth_host_port="$2"
  local name="sbox${idx}"

  docker rm -f "$name" >/dev/null 2>&1 || true
  make_cfg "$idx" "$auth_host_port"

  # Chạy sing-box (không còn field legacy -> không cần biến ENABLE_DEPRECATED...)
  docker run -d --name "$name" \
    --privileged --cap-add=NET_ADMIN --device /dev/net/tun \
    -v "$PWD/sbox_${idx}.json:/etc/sing-box/config.json:ro" \
    --restart=always "$IMG" run -c /etc/sing-box/config.json >/dev/null

  # Đợi container lên
  for _ in {1..15}; do
    st="$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
    [[ "$st" == "running" ]] && break
    sleep 0.7
  done

  echo "------------------------------------------------------------"
  echo "[ROUTE $idx] SOCKS5: ${auth_host_port}"
  # Test nhanh qua IP (không phụ thuộc DNS ở host)
  if docker run --rm --network=container:"$name" curlimages/curl -4 -s -o /dev/null \
       -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' https://1.1.1.1; then
    echo "[ROUTE $idx] RUNNING: $name"
    echo "→ App SOCKS5H (DNS tại proxy):  curl --socks5-hostname ${auth_host_port} https://..."
    echo "→ App chia sẻ netns:           docker run ... --network=container:${name} <image> ..."
  else
    echo "[ROUTE $idx] latency(IP): FAIL"
    echo "[ROUTE $idx] Gợi ý: docker logs ${name} ; docker inspect ${name} --format '{{json .State}}'"
  fi
}

down_all() {
  for i in $(seq 1 ${#PROXIES[@]}); do
    docker rm -f "sbox$i" >/dev/null 2>&1 || true
    rm -f "sbox_${i}.json" || true
  done
  echo "[DONE] Đã gỡ tất cả routes."
}

status_all() {
  for i in $(seq 1 ${#PROXIES[@]}); do
    local name="sbox$i"
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
      printf "[STATUS] %-6s " "$name"
      docker run --rm --network=container:"$name" curlimages/curl -s https://1.1.1.1/cdn-cgi/trace | grep '^ip=' || true
    else
      echo "[STATUS] $name: not running"
    fi
  done
}

case "${1:-up}" in
  up)
    for i in $(seq 1 ${#PROXIES[@]}); do
      up_one "$i" "${PROXIES[$((i-1))]}"
    done
    echo
    echo "✅ ĐÃ KHỞI TẠO ${#PROXIES[@]} ROUTES (sing-box, DNS qua proxy)."
    echo "👉 Gắn app:  docker run ... --network=container:sboxN <image> ..."
    echo "👉 App CLI SOCKS5H:  curl --socks5-hostname USER:PASS@IP:PORT https://..."
    ;;
  status)
    status_all
    ;;
  down)
    down_all
    ;;
  *)
    echo "Usage: $0 [up|status|down]"; exit 1;;
esac
EOF

chmod +x sbox_multi.sh
./sbox_multi.sh up
