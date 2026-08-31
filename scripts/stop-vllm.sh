#!/usr/bin/env bash
# stop-vllm.sh — Gracefully stop vLLM and ensure 100% GPU memory release
set -uo pipefail

PIDS=$(pgrep -f "vllm|EngineCore|resource_tracker" || true)
if [ -n "$PIDS" ]; then
  echo "SIGTERM -> $PIDS"
  # shellcheck disable=SC2086  # $PIDS is a list of pids; word-splitting is intended
  kill $PIDS 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -f "vllm|EngineCore" >/dev/null || break
    sleep 1
  done
  if pgrep -f "vllm|EngineCore" >/dev/null; then
    echo "SIGKILL remaining..."
    pkill -9 -f "vllm|EngineCore" 2>/dev/null || true
    sleep 2
  fi
fi

# Also kill any remaining compute app holding GPU VRAM
COMPUTE_PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null || true)
if [ -n "$COMPUTE_PIDS" ]; then
  echo "Killing remaining GPU compute PIDs: $COMPUTE_PIDS"
  # shellcheck disable=SC2086  # multiple pids; word-splitting is intended
  kill -9 $COMPUTE_PIDS 2>/dev/null || true
  sleep 2
fi

echo "--- GPU state after stop ---"
nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader
