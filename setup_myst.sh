#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu cấu hình myst..."

echo "[INFO] Cấu hình myst1 ..."
docker exec myst1 myst config set payments.zero-stake-unsettled-amount 0.1
sleep 3   # chờ myst1 xử lý

echo "[INFO] Cấu hình myst2 ..."
docker exec myst2 myst config set payments.zero-stake-unsettled-amount 0.1
sleep 3   # chờ myst2 xử lý

echo "[INFO] Restart myst1 và myst2 ..."
docker restart myst1 myst2

echo "[DONE] Setup Myst hoàn tất ✅"
