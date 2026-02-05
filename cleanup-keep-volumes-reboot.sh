#!/bin/bash
set -u # Cho phép script tiếp tục chạy dù gặp lỗi nhỏ

echo "=== [UPDATE MODE] Dọn dẹp để Cập nhật phiên bản mới ==="

# 1. Dừng và Xóa toàn bộ Container
echo "[1/5] Dừng và xóa Container..."
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
    docker update --restart=no $(docker ps -aq) 2>/dev/null || true
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm -f $(docker ps -aq)
fi

# 2. Xóa Image (BẮT BUỘC ĐỂ CẬP NHẬT MỚI)
# Lệnh này sẽ xóa tất cả images, buộc lần cài đặt sau phải tải bản mới nhất
echo "[2/5] Xóa toàn bộ Images cũ..."
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
    docker rmi -f $(docker images -q)
    echo "  -> Đã xóa sạch Images."
else
    echo "  -> Không có Images nào."
fi

# 3. Dọn dẹp Network (BẢO VỆ MẶC ĐỊNH)
echo "[3/5] Xóa Network thừa (Giữ lại bridge/host/none)..."
docker network prune -f > /dev/null 2>&1
# Chỉ xóa network có tên cụ thể, không đụng vào network hệ thống
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
    docker network rm "$net" || true
    echo "  -> Đã xóa network: $net"
done

# 4. Xóa rác hệ thống (Cronjob & IPTables)
echo "[4/5] Dọn dẹp Cronjob và Rules mạng cũ..."
iptables -t nat -F POSTROUTING # Xóa rule SNAT cũ
crontab -r 2>/dev/null || true # Xóa cronjob user root
find /etc/cron.d/ -type f -exec grep -lE "docker|install.sh|watchdog" {} + 2>/dev/null | xargs -r rm -f

# 5. GIỮ NGUYÊN VOLUME (Không có lệnh docker volume rm ở đây)
echo "[INFO] VOLUME DỮ LIỆU ĐƯỢC GIỮ NGUYÊN."

echo "=== [DONE] Hệ thống sẽ Reboot sau 5 giây để áp dụng thay đổi ==="
sleep 5
reboot
