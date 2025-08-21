#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu cấu hình myst..."

echo "[INFO] Cấu hình myst1 ..."
docker exec -T myst1 sh -c "myst config set payments.zero-stake-unsettled-amount 0.1"

echo "[INFO] Cấu hình myst2 ..."
docker exec -T myst2 sh -c "myst config set payments.zero-stake-unsettled-amount 0.1"

echo "[INFO] Restart myst1 và myst2 ..."
docker restart myst1 myst2

echo "[DONE] Setup Myst hoàn tất ✅"
