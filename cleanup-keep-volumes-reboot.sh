#!/bin/bash
set -euo pipefail

echo "[INFO] === FORCE CLEANUP: Xoá tất cả containers, images, networks (giữ volumes) ==="

# 1. Disable restart policies để tránh tự spawn lại
echo "[INFO] Tắt restart policy của toàn bộ containers..."
for c in $(docker ps -aq); do
  docker update --restart=no "$c" >/dev/null 2>&1 || true
done
sleep 2

# 2. Remove ALL containers
if [ "$(docker ps -aq | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá tất cả containers..."
  docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có container nào."
fi
sleep 2

# 3. Remove ALL docker images
if [ "$(docker images -q | wc -l)" -gt 0 ]; then
  echo "[INFO] Xoá tất cả images..."
  docker rmi -f $(docker images -q) >/dev/null 2>&1 || true
else
  echo "[INFO] Không có image nào."
fi
sleep 2

# 4. Remove custom docker networks (giữ bridge/host/none)
echo "[INFO] Xoá toàn bộ networks tuỳ chỉnh..."
for net in $(docker network ls --format '{{.Name}}' | grep -vE 'bridge|host|none'); do
  docker network rm "$net" >/dev/null 2>&1 || true
done
sleep 2

# 5. Thông báo hoàn tất
echo "[INFO] === Dọn dẹp hoàn tất (volumes giữ nguyên). ==="
