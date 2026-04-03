#!/bin/bash
set -euo pipefail

# Hàm in log cho đẹp
log() { echo -e "\e[32m[INFO]\e[0m $1"; }

log "Bắt đầu quét danh sách container Mysterium..."

# 1. Tự động lấy danh sách tên các container đang chạy có chứa chữ "myst"
# Lệnh này sẽ trả về danh sách cách nhau bởi dấu cách
MYST_CONTAINERS=$(docker ps --format '{{.Names}}' | grep "myst" || true)

# Kiểm tra nếu không tìm thấy container nào
if [ -z "$MYST_CONTAINERS" ]; then
    echo -e "\e[33m[WARN]\e[0m Không tìm thấy container nào có tên chứa 'myst'. Dừng script."
    exit 0
fi

log "Tìm thấy các container: $(echo $MYST_CONTAINERS | tr '\n' ' ')"

# 2. Vòng lặp cấu hình cho từng container
for container in $MYST_CONTAINERS; do
    log "Đang cấu hình cho: $container ..."
    
    # Thực hiện lệnh cấu hình, dùng || true để tránh dừng script nếu container vừa khởi động chưa sẵn sàng
    docker exec "$container" myst config set payments.zero-stake-unsettled-amount 1 || true
    
    # Nghỉ 1 chút để tránh quá tải I/O nếu số lượng container lớn
    sleep 1
done

# 3. Khởi động lại tất cả cùng một lúc để áp dụng cấu hình
log "Đang restart lại toàn bộ cụm Myst..."
docker restart $MYST_CONTAINERS

log "Setup Myst hoàn tất cho $(echo "$MYST_CONTAINERS" | wc -w) container ✅"
