#!/bin/bash
set -euo pipefail

echo "[INFO] Bắt đầu cấu hình myst..."

echo "[INFO] Cấu hình myst1 ..."
docker exec myst_main myst config set payments.zero-stake-unsettled-amount 1 || true
sleep 2

echo "[INFO] Cấu hình myst2 ..."
docker exec myst_sub myst config set payments.zero-stake-unsettled-amount 1 || true
sleep 2

echo "[INFO] Restart myst1 và myst2 ..."
docker restart myst_main myst_sub

echo "[DONE] Setup Myst hoàn tất ✅"
