#!/usr/bin/env bash
# bootstrap-runtime.sh — Restore or build the fast local vLLM runtime on RunPod.
#
# The 156 GB checkpoint lives on the persistent network volume, but the vLLM
# venv and JIT/compile caches must live on the LOCAL container disk: /workspace
# is MooseFS (~450 MB/s sequential, but only ~32 file-creates/sec), which is
# fine for the big checkpoint yet ~600x too slow for the many tiny files a
# venv and Triton/Inductor cache create. So the runtime is built once onto
# /opt + /root, then snapshotted to the volume so later pod starts restore it
# in seconds instead of rebuilding.
set -euo pipefail

RUNTIME_ARCHIVE="/workspace/runtime/runtime-cache.tar.zst"
mkdir -p /opt/venvs /root/.cache /workspace/runtime /workspace/logs /workspace/secrets

# 1. Already built on this container's local disk -> nothing to do.
if [ -x "/opt/venvs/dsv4/bin/vllm" ]; then
  echo "vLLM runtime already present at /opt/venvs/dsv4"
  exit 0
fi

# 2. Fast path: restore the precompiled runtime + JIT cubins from the volume.
if [ -s "$RUNTIME_ARCHIVE" ] && command -v zstd >/dev/null 2>&1; then
  echo "Restoring vLLM runtime and precompiled JIT caches from $RUNTIME_ARCHIVE..."
  tar -I zstd -xf "$RUNTIME_ARCHIVE" -C /
  echo "Runtime restored in seconds."
  exit 0
fi

# 3. Cold build: install vLLM onto the local overlay disk with uv.
echo "No runtime snapshot found. Building local vLLM 0.26.0 runtime with uv..."
export UV_CACHE_DIR=/root/.cache/uv
export UV_LINK_MODE=hardlink
command -v uv >/dev/null 2>&1 || (echo "installing uv..."; curl -LsSf https://astral.sh/uv/install.sh | sh; export PATH="$HOME/.local/bin:$PATH")
uv venv /opt/venvs/dsv4 --python /usr/bin/python3 --seed
# shellcheck source=/dev/null
source /opt/venvs/dsv4/bin/activate
uv pip install "vllm==0.26.0" --torch-backend=auto
echo "Runtime built successfully."

# 4. Snapshot the fresh build back to the volume so the next start is instant.
#    Skippable with SNAPSHOT_RUNTIME=0 (e.g. to keep the volume minimal).
if [ "${SNAPSHOT_RUNTIME:-1}" = "1" ] && command -v zstd >/dev/null 2>&1; then
  echo "Snapshotting runtime to $RUNTIME_ARCHIVE for fast future starts..."
  tar -I 'zstd -3 -T0' -cf "$RUNTIME_ARCHIVE.tmp" \
      /opt/venvs/dsv4 /root/.cache 2>/dev/null || true
  mv -f "$RUNTIME_ARCHIVE.tmp" "$RUNTIME_ARCHIVE" 2>/dev/null || true
  echo "Snapshot written ($(du -h "$RUNTIME_ARCHIVE" 2>/dev/null | cut -f1)). Future starts restore in seconds."
fi
