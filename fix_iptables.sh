#!/bin/bash
set -euo pipefail

# Lấy IP public (chọn card ens5, nếu khác thì sửa lại)
IP_ALLA=$(/sbin/ip -4 -o addr show scope global ens5 | awk '{gsub(/\/.*/,"",$4); print $4}' | head -n1)
IP_ALLB=$IP_ALLA   # dùng cùng IP cho cả 2 mạng (nếu cần có thể tách IP riêng)

echo "[INFO] Đang fix iptables..."

# Hàm fix rule SNAT
fix_rule() {
  NET=$1
  IP=$2
  if ! iptables -t nat -C POSTROUTING -s ${NET} -j SNAT --to-source ${IP} 2>/dev/null; then
    echo "[WARN] Thiếu rule cho ${NET}, thêm lại..."
    iptables -t nat -A POSTROUTING -s ${NET} -j SNAT --to-source ${IP}
    NEED_RESTART=1
  fi
}

NEED_RESTART=0
fix_rule "192.168.33.0/24" "$IP_ALLA"
fix_rule "192.168.34.0/24" "$IP_ALLB"

# Nếu rule bị thiếu và đã được thêm → restart lại container để chắc kết nối
if [ $NEED_RESTART -eq 1 ]; then
  echo "[INFO] Restart toàn bộ container để làm mới kết nối..."
  docker restart $(docker ps -q) || true
fi

echo "[INFO] Hoàn tất fix iptables."
