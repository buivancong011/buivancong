#!/bin/bash
set -e

echo "================= KIỂM TRA HỆ THỐNG ================="

# Kiểm tra Docker
if ! systemctl is-active --quiet docker; then
    echo "[❌] Docker chưa chạy"
else
    echo "[✅] Docker đang chạy"
fi

# Kiểm tra iptables rules
echo "[ℹ️] Kiểm tra NAT iptables:"
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic ens5 | awk '{gsub(/\/.*/,"",$4); print $4}')

iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null \
    && echo "[✅] NAT my_network_1 OK" || echo "[❌] NAT my_network_1 lỗi"
iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null \
    && echo "[✅] NAT my_network_2 OK" || echo "[❌] NAT my_network_2 lỗi"

# Kiểm tra networks
echo "[ℹ️] Docker networks:"
docker network ls | grep -E "my_network_1|my_network_2"

# Kiểm tra containers
echo "[ℹ️] Trạng thái containers:"
for c in tm1 tm2 repocket1 repocket2 myst1 myst2 earnfm1 earnfm2 packetsdk1 packetsdk2 ur1 ur2; do
    if docker ps --format '{{.Names}}' | grep -wq "$c"; then
        echo "[✅] $c đang chạy"
    else
        echo "[❌] $c không chạy"
    fi
done

echo "================= HOÀN TẤT KIỂM TRA ================="
