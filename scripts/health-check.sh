#!/usr/bin/env bash
# health-check.sh — Instant server and GPU status report
set -euo pipefail
K=$(tr -d '\n' < /workspace/secrets/vllm_api_key 2>/dev/null || echo "")

echo "=== GPU Status ==="
nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,utilization.gpu --format=csv

echo "=== Process Status ==="
# shellcheck disable=SC2009  # need the full ps columns (cpu/mem/etime), not just pids
ps -eo pid,pcpu,pmem,etime,args | grep -E "vllm|EngineCore" | grep -v grep || echo "No active vLLM process"

echo "=== Port 8000 Health ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}\n" -m 3 http://127.0.0.1:8000/health 2>/dev/null || echo "000")
echo "HTTP /health: $HTTP_CODE"

if [ -n "$K" ] && [ "$HTTP_CODE" = "200" ]; then
  echo "=== /v1/models ==="
  curl -s -m 5 http://127.0.0.1:8000/v1/models -H "Authorization: Bearer $K" | cut -c1-300
  echo
fi
