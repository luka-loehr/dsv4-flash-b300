# syntax=docker/dockerfile:1
# dsv4-flash-b300 — RUNTIME layer for the all-in-one B300 image.
#
# This builds the runtime: vLLM 0.26 (CUDA 13 / torch 2.11) + the full FlashInfer
# TRTLLM-GEN cubin set + the server scripts + the entrypoint. It does NOT contain
# the 156 GB checkpoint — that layer is added on top by ops/build-on-runpod.sh
# (buildah copy from the model volume), producing the final ~166 GB image.
#
# The runtime layer alone is small enough to build in CI; the model layer needs a
# big-disk host, which is why the model is added separately.

FROM runpod/pytorch:1.0.3-cu1300-torch291-ubuntu2404

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends zstd curl ca-certificates openssh-server \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:/opt/venvs/dsv4/bin:${PATH}" \
    UV_LINK_MODE=copy

RUN uv venv /opt/venvs/dsv4 --python /usr/bin/python3 --seed \
    && uv pip install --python /opt/venvs/dsv4/bin/python "vllm==0.26.0" \
        --extra-index-url https://download.pytorch.org/whl/cu130 \
        --index-strategy unsafe-best-match \
    && /opt/venvs/dsv4/bin/python -c "import vllm, torch; print('vllm', vllm.__version__, 'torch', torch.__version__)"

# Pre-fetch FlashInfer cubins so first serve needs (near) zero downloads. The full
# TRTLLM-GEN set is ~16k cubins and NVIDIA's artifactory throttles hard (hours to
# pull all of them), so this is time-bounded: it bakes what it can within the
# window and vLLM fetches any remaining shape on first serve. Not fatal if partial.
ENV FLASHINFER_CUBIN_DIR=/root/.cache/flashinfer/cubins \
    FLASHINFER_CUBIN_DOWNLOAD_THREADS=16 \
    FLASHINFER_CUBIN_MINUTES=15
RUN mkdir -p "$FLASHINFER_CUBIN_DIR" \
    && ( timeout "${FLASHINFER_CUBIN_MINUTES}m" /opt/venvs/dsv4/bin/flashinfer download-cubin || true ) \
    && du -sh /root/.cache/flashinfer || true

COPY scripts /opt/dsv4-flash-b300/scripts
COPY client  /opt/dsv4-flash-b300/client
COPY containers/entrypoint.sh /usr/local/bin/dsv4-entrypoint
RUN chmod +x /usr/local/bin/dsv4-entrypoint /opt/dsv4-flash-b300/scripts/*.sh

ENV DSV4_PROFILE=fast \
    DSV4_MODEL=/models/DeepSeek-V4-Flash-0731-abliterated \
    HF_HUB_DISABLE_TELEMETRY=1 \
    PORT=8000

LABEL org.opencontainers.image.source="https://github.com/luka-loehr/dsv4-flash-b300" \
      org.opencontainers.image.description="All-in-one: DeepSeek-V4-Flash-0731 (abliterated) + vLLM 0.26 + FlashInfer cubins for one NVIDIA B300. No model-hub download and no volume; kernels JIT-compile on first serve. Anthropic + OpenAI APIs for Claude Code, Codex, Pi, OpenCode, Aider." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.title="dsv4-flash-b300"

EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/dsv4-entrypoint"]
