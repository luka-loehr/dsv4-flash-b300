#!/usr/bin/env bash
# install.sh — set up local launchers for every supported agent CLI.
#
# Writes one shared config (~/.config/dsv4/env) with your pod URL + API key, then
# installs the per-tool launchers into ~/.local/bin. Each launcher points its tool
# at the same endpoint — Claude Code via the Anthropic Messages API, everything
# else via the OpenAI-compatible API (both served by vLLM at <pod>/v1).
set -euo pipefail

CFG_DIR="$HOME/.config/dsv4"
BIN_DIR="$HOME/.local/bin"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$CFG_DIR" "$BIN_DIR"

if [ ! -f "$CFG_DIR/env" ]; then
  echo "Set up dsv4-flash-b300. Your running pod prints these in its boot log."
  read -rp "Pod URL (e.g. https://<pod-id>-8000.proxy.runpod.net): " POD_URL
  read -rsp "API key (from /workspace/secrets/vllm_api_key on the pod): " API_KEY
  echo
  cat > "$CFG_DIR/env" <<ENVEOF
export DSV4_POD_URL="${POD_URL%/}"
export DSV4_API_KEY="$API_KEY"
ENVEOF
  chmod 600 "$CFG_DIR/env"
  echo "Wrote $CFG_DIR/env (mode 600)."
else
  echo "Using existing $CFG_DIR/env (edit it to change the pod URL or key)."
fi

for l in cc-dsv4 codex-dsv4 opencode-dsv4 pi-dsv4 aider-dsv4; do
  install -m 0755 "$SRC_DIR/$l" "$BIN_DIR/$l"
  echo "installed $BIN_DIR/$l"
done

echo
echo "Detected harness CLIs on this machine:"
for pair in "claude:cc-dsv4" "codex:codex-dsv4" "opencode:opencode-dsv4" "pi:pi-dsv4" "aider:aider-dsv4"; do
  tool="${pair%%:*}"; launcher="${pair##*:}"
  if command -v "$tool" >/dev/null 2>&1; then
    printf "  \033[32m✓\033[0m %-9s → run: %s\n" "$tool" "$launcher"
  else
    printf "  \033[33m–\033[0m %-9s (not installed; install it, then run %s)\n" "$tool" "$launcher"
  fi
done
echo
echo "Make sure $BIN_DIR is on your PATH. When you redeploy the pod, update"
echo "DSV4_POD_URL in $CFG_DIR/env (or pass DSV4_POD_URL=... in front of any launcher)."
