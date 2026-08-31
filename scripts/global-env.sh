#!/usr/bin/env bash
# Shared environment for the DeepSeek-V4-Flash B300 deployment.
# Source this before anything else:  source /workspace/scripts/global-env.sh

export PATH="$HOME/.local/bin:$PATH"

# --- Runtime location: LOCAL disk (fast). Rebuilt by bootstrap-runtime.sh ---
export DSV4_VENV="/opt/venvs/dsv4"
# Overridable: the all-in-one image bakes the model at /models; a volume deploy
# would set /workspace/models. Default keeps the historical path.
export DSV4_MODEL="${DSV4_MODEL:-/models/DeepSeek-V4-Flash-0731-abliterated}"

# --- Hugging Face: persistent, but only used for small config/tokenizer reads
export HF_HOME="/workspace/cache/huggingface"
export HF_XET_CACHE="/workspace/cache/xet"
export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DOWNLOAD_TIMEOUT=300
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_OFFLINE=1

# --- Compile / JIT caches: LOCAL DISK ONLY (fast metadata & tiny creates) ---
export VLLM_CACHE_ROOT="/root/.cache/vllm"
export TRITON_CACHE_DIR="/root/.cache/triton"
export TORCHINDUCTOR_CACHE_DIR="/root/.cache/torchinductor"
export CUDA_CACHE_PATH="/root/.cache/cuda"
export FLASHINFER_WORKSPACE_BASE="/root/.cache/flashinfer"
mkdir -p "$VLLM_CACHE_ROOT" "$TRITON_CACHE_DIR" "$TORCHINDUCTOR_CACHE_DIR" \
         "$CUDA_CACHE_PATH" "$FLASHINFER_WORKSPACE_BASE" 2>/dev/null || true

# --- API key: exported as VLLM_API_KEY so it never appears in `ps` ---------
if [ -s /workspace/secrets/vllm_api_key ]; then
  VLLM_API_KEY="$(tr -d '\n' < /workspace/secrets/vllm_api_key)"
  export VLLM_API_KEY
fi

# --- Server addressing ----------------------------------------------------
export DSV4_HOST="0.0.0.0"
export DSV4_PORT="8000"
export DSV4_ALIAS="dsv4"

[ -x "$DSV4_VENV/bin/python" ] && export PATH="$DSV4_VENV/bin:$PATH"
