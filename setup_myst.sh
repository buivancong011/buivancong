#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu cấu hình myst..."

echo "[INFO] Cấu hình myst1 ..."
docker exec -it myst1 myst config set payments.zero-stake-unsettled-amount 0.1
sleep 2

echo "[INFO] Cấu hình myst2 ..."
docker exec -it myst2 myst config set payments.zero-stake-unsettled-amount 0.1
sleep 2

echo "[INFO] Restart myst1 và myst2 ..."
docker restart myst1 myst2

echo "[DONE] Setup Myst hoàn tất ✅"
