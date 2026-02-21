#!/bin/bash
set -u 

echo "=== [CLEAN MODE] Dọn dẹp TOÀN BỘ (Chỉ giữ lại Mysterium Data) ==="

# 1. Dừng và Xóa toàn bộ Container
echo "[1/5] Dừng và xóa toàn bộ Container..."
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
    # Tắt restart policy để tránh container tự bật lại khi đang xóa
    docker update --restart=no $(docker ps -aq) 2>/dev/null || true
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq)
    echo "  -> Đã dọn sạch Container."
fi

# 2. Xóa toàn bộ Images
echo "[2/5] Xóa toàn bộ Images cũ..."
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
    docker rmi -f $(docker images -q)
    echo "  -> Đã xóa sạch Images."
else
    echo "  -> Không có Images nào."
fi

# 3. Dọn dẹp Network
echo "[3/5] Xóa Network thừa..."
docker network prune -f > /dev/null 2>&1
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
    docker network rm "$net" || true
    echo "  -> Đã xóa network: $net"
done

# 4. Xóa rác hệ thống (Cronjob & IPTables)
echo "[4/5] Dọn dẹp Cronjob và Rules mạng cũ..."
iptables -t nat -F POSTROUTING 
crontab -r 2>/dev/null || true 
find /etc/cron.d/ -type f -exec grep -lE "docker|install.sh|watchdog" {} + 2>/dev/null | xargs -r rm -f

# 5. XỬ LÝ VOLUME (QUAN TRỌNG: CHỈ GIỮ LẠI MYST-DATA)
echo "[5/5] Xóa Volume rác (CHỈ BẢO VỆ myst-data)..."

if [ "$(docker volume ls -q | wc -l)" -gt 0 ]; then
    for vol in $(docker volume ls -q); do
        # --- LOGIC BẢO VỆ DUY NHẤT MYST-DATA ---
        if [[ "$vol" == "myst-data"* ]]; then
            echo "  -> [BẢO VỆ] Giữ lại dữ liệu Mysterium: $vol"
        else
            # Tất cả các volume khác bao gồm ur_data, earnfm, repocket... sẽ bị bay màu
            echo "  -> [XÓA] Đang xóa volume: $vol"
            docker volume rm "$vol" || true
        fi
    done
else
    echo "  -> Không có volume nào để xóa."
fi

echo "------------------------------------------------------------"
echo "✅ Hệ thống đã sạch bóng quân thù (Trừ Mysterium)."
echo "🚀 Sẵn sàng để chạy script Install mới."
echo "=== Hệ thống sẽ Reboot sau 5 giây... ==="
sleep 5
reboot
