#!/usr/bin/env bash
# start-vllm.sh — Start the DeepSeek-V4-Flash-0731-abliterated server on 1x NVIDIA B300
# Usage: start-vllm.sh [fast|safe] [--fg]
set -euo pipefail
# shellcheck source=/dev/null
source /workspace/scripts/global-env.sh

PROFILE="${1:-fast}"
FG="${2:-}"
LOG=/workspace/logs/vllm.log

if [ ! -x "$DSV4_VENV/bin/vllm" ]; then
  echo "Runtime missing at $DSV4_VENV -- auto-restoring from snapshot..."
  /workspace/scripts/bootstrap-runtime.sh
fi
if [ ! -s "$DSV4_MODEL/config.json" ]; then
  echo "ERROR: model missing at $DSV4_MODEL" >&2
  exit 1
fi
if pgrep -f "vllm.entrypoints|vllm serve" >/dev/null 2>&1; then
  echo "ERROR: a vLLM process is already running. Use stop-vllm.sh first." >&2
  exit 1
fi

ARGS=(
  "$DSV4_MODEL"
  --served-model-name "$DSV4_ALIAS"
  --host "$DSV4_HOST" --port "$DSV4_PORT"
  --trust-remote-code
  --tokenizer-mode deepseek_v4
  --tensor-parallel-size 1
  --pipeline-parallel-size 1
  --kv-cache-dtype fp8
  --block-size 256
  --enable-prefix-caching
  --reasoning-parser deepseek_v4
  --tool-call-parser deepseek_v4
  --enable-auto-tool-choice
  --safetensors-prefetch-num-threads 16
  --safetensors-load-strategy prefetch
)

case "$PROFILE" in
  safe)
    ARGS+=(
      --gpu-memory-utilization 0.90
      --max-model-len 1048576
      --max-num-seqs 8
      --max-num-batched-tokens 8192
      # diagnostic only: logs full prompts to the volume. Never in 'fast'.
      --enable-log-requests
    )
    ;;
  fast)
    ARGS+=(
      --gpu-memory-utilization 0.92
      --max-model-len 1048576
      --max-num-seqs 4
      --max-num-batched-tokens 32768
      --performance-mode interactivity
      --attention-config '{"use_fp4_indexer_cache":true}'
      --speculative-config "{\"method\":\"dspark\",\"num_speculative_tokens\":${DSV4_SPEC_TOKENS:-7},\"draft_sample_method\":\"${DSV4_DRAFT_SAMPLE:-probabilistic}\"}"
      --compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE"}'
    )
    [ -n "${DSV4_MOE_BACKEND:-}" ] && ARGS+=(--moe-backend "$DSV4_MOE_BACKEND")
    ;;
  *) echo "unknown profile: $PROFILE (want safe|fast)" >&2; exit 2 ;;
esac

[ -f "$LOG" ] && mv "$LOG" "$LOG.$(date +%Y%m%d-%H%M%S)"
{ ls -1t /workspace/logs/vllm.log.* 2>/dev/null || true; } | tail -n +6 | xargs -r rm -f

echo "profile=$PROFILE  model=$DSV4_MODEL"
echo "log=$LOG"
printf 'args:'; printf ' %q' "${ARGS[@]}"; echo

if [ "$FG" = "--fg" ]; then
  exec "$DSV4_VENV/bin/vllm" serve "${ARGS[@]}" 2>&1 | tee "$LOG"
else
  setsid nohup "$DSV4_VENV/bin/vllm" serve "${ARGS[@]}" > "$LOG" 2>&1 < /dev/null &
  echo "started pid=$! ; tail -f $LOG"
fi
