#!/usr/bin/env bash
# dsv4-entrypoint — entrypoint for the all-in-one dsv4-flash-b300 image.
#
# EVERYTHING is baked into the image: the 156 GB checkpoint (/models), the vLLM
# 0.26 runtime (/opt/venvs/dsv4), and the full FlashInfer cubin set
# (/root/.cache/flashinfer). There is nothing to download and no volume to mount
# — pull the image, run it on a Blackwell GPU, and it serves. Only the GPU-JIT'd
# TileLang/DeepGEMM kernels compile on first serve (a few minutes, no downloads).
set -uo pipefail

export DSV4_MODEL="${DSV4_MODEL:-/models/DeepSeek-V4-Flash-0731-abliterated}"
LOG="/workspace/logs/vllm.log"
banner() { printf '\n\033[1;36m════════════════════════════════════════════════════════════════\033[0m\n'; }

echo "[dsv4] all-in-one image boot — model + runtime + cubins baked, zero downloads"
mkdir -p /workspace/scripts /workspace/secrets /workspace/logs

# 0. SSH (RunPod injects PUBLIC_KEY; we own the entrypoint so we set it up).
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  grep -qxF "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  /usr/sbin/sshd 2>/dev/null || service ssh start 2>/dev/null || true
fi

# 1. Server scripts are baked at /opt/dsv4-flash-b300/scripts.
cp -f /opt/dsv4-flash-b300/scripts/*.sh /workspace/scripts/ 2>/dev/null || true
chmod +x /workspace/scripts/*.sh 2>/dev/null || true

# 2. API key: use $DSV4_API_KEY if provided at run time, else generate one.
if [ -n "${DSV4_API_KEY:-}" ]; then
  printf '%s' "$DSV4_API_KEY" > /workspace/secrets/vllm_api_key
elif [ ! -s /workspace/secrets/vllm_api_key ]; then
  printf 'sk-dsv4-%s' "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" > /workspace/secrets/vllm_api_key
fi
chmod 600 /workspace/secrets/vllm_api_key
API_KEY="$(tr -d '\n' < /workspace/secrets/vllm_api_key)"

# 3. Sanity: the baked model must be present.
if [ ! -s "$DSV4_MODEL/config.json" ]; then
  echo "[dsv4] FATAL: baked model missing at $DSV4_MODEL (bad image build)" >&2
  exec sleep infinity
fi

# 4. Serve (runtime + cubins already local; nothing to fetch).
echo "[dsv4] starting vLLM (profile=${DSV4_PROFILE:-fast}) from baked runtime..."
bash /workspace/scripts/start-vllm.sh "${DSV4_PROFILE:-fast}"

# 5. Wait for health (only GPU-JIT kernels compile now — no downloads).
echo "[dsv4] waiting for http://127.0.0.1:8000/health ..."
READY=0
for _ in $(seq 1 180); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8000/health 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && { READY=1; break; }
  sleep 5
done

# 6. Connection banner.
POD="${RUNPOD_POD_ID:-<pod-id>}"
PUBLIC_URL="https://${POD}-8000.proxy.runpod.net"
banner
[ "$READY" = "1" ] && echo "  ✅  DeepSeek-V4-Flash is SERVING (zero downloads)" \
                   || echo "  ⏳  not healthy yet — GPU kernels still compiling; see the log below"
echo
echo "  Endpoint : $PUBLIC_URL   (model: dsv4)"
echo "             Anthropic API  →  $PUBLIC_URL/v1/messages        (Claude Code)"
echo "             OpenAI API     →  $PUBLIC_URL/v1/chat/completions (Codex · Pi · OpenCode · Aider)"
echo "  API key  : $API_KEY"
echo
echo "  Connect any agent CLI from your Mac:"
echo "      git clone https://github.com/luka-loehr/dsv4-flash-b300 && cd dsv4-flash-b300"
echo "      DSV4_POD_URL=$PUBLIC_URL ./client/install.sh   # paste the API key above"
echo "      cc-dsv4   # Claude Code   (or codex-dsv4 · pi-dsv4 · opencode-dsv4 · aider-dsv4)"
banner

# 7. Keep the container alive and stream the server log.
exec tail -F "$LOG"
