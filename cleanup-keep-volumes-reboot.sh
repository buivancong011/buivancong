#!/bin/bash
set -u # Cho phép script tiếp tục chạy dù gặp lỗi nhỏ

echo "=== [UPDATE MODE] Dọn dẹp SẠCH SẼ (Bảo vệ Mysterium Data) ==="

# 1. Dừng và Xóa toàn bộ Container
echo "[1/5] Dừng và xóa Container..."
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
    docker update --restart=no $(docker ps -aq) 2>/dev/null || true
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq)
fi

# 2. Xóa Image (BẮT BUỘC ĐỂ CẬP NHẬT MỚI)
echo "[2/5] Xóa toàn bộ Images cũ..."
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
    docker rmi -f $(docker images -q)
    echo "  -> Đã xóa sạch Images."
else
    echo "  -> Không có Images nào."
fi

# 3. Dọn dẹp Network (BẢO VỆ MẶC ĐỊNH)
echo "[3/5] Xóa Network thừa..."
docker network prune -f > /dev/null 2>&1
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
    docker network rm "$net" || true
    echo "  -> Đã xóa network: $net"
done

# 4. Xóa rác hệ thống (Cronjob & IPTables)
echo "[4/5] Dọn dẹp Cronjob và Rules mạng cũ..."
iptables -t nat -F POSTROUTING # Xóa rule SNAT cũ
crontab -r 2>/dev/null || true # Xóa cronjob user root
find /etc/cron.d/ -type f -exec grep -lE "docker|install.sh|watchdog" {} + 2>/dev/null | xargs -r rm -f

# 5. XỬ LÝ VOLUME (Đoạn mới thêm)
echo "[5/5] Xóa Volume rác (GIỮ LẠI myst-data1 & myst-data2)..."
# Lấy danh sách tất cả volume hiện có
if [ "$(docker volume ls -q | wc -l)" -gt 0 ]; then
    for vol in $(docker volume ls -q); do
        # KIỂM TRA: Nếu tên volume là myst-data1 hoặc myst-data2 thì BỎ QUA (không xóa)
        if [[ "$vol" == "myst-data1" || "$vol" == "myst-data2" ]]; then
            echo "  -> [SKIP] Đang bảo vệ dữ liệu: $vol"
        else
            # Nếu không phải myst thì xóa thẳng tay
            echo "  -> [DELETE] Xóa volume rác: $vol"
            docker volume rm "$vol" || true
        fi
    done
else
    echo "  -> Không có volume nào để xóa."
fi

echo "=== [DONE] Hệ thống sẽ Reboot sau 5 giây... ==="

reboot
