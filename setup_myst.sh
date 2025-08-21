#!/bin/bash
set -euo pipefail

# ==== CONFIG ====
CONTAINERS=("myst1" "myst2")
VALUE="0.1"

echo "[INFO] Bắt đầu cấu hình myst..."
for c in "${CONTAINERS[@]}"; do
  echo "[INFO] Cấu hình $c ..."
  sudo docker exec -it "$c" myst config set payments.zero-stake-unsettled-amount "$VALUE"
done

echo "[INFO] Restart containers..."
sudo docker restart "${CONTAINERS[@]}"

echo "[DONE] ✅ Myst config đã được cập nhật và containers đã restart"
