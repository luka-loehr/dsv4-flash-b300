#!/usr/bin/env bash
# bench.sh — single-stream throughput probe + Anthropic-endpoint validation.
# Run on the pod after start-vllm.sh reports healthy.
set -uo pipefail

BASE="http://127.0.0.1:8000"
K="$(tr -d '\n' < /workspace/secrets/vllm_api_key 2>/dev/null || echo "")"
AUTH=(-H "Authorization: Bearer $K")
PROMPT="${1:-Write a concise Rust function that returns the nth Fibonacci number, then explain it in two sentences.}"
MAXTOK="${2:-400}"

echo "=== /health ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -m 5 "$BASE/health"

echo "=== /v1/models ==="
curl -s -m 5 "$BASE/v1/models" "${AUTH[@]}" | head -c 400; echo

echo "=== OpenAI /v1/chat/completions (single stream, ${MAXTOK} tok) ==="
REQ="$(PROMPT="$PROMPT" MAXTOK="$MAXTOK" python3 -c 'import os,json;print(json.dumps({"model":"dsv4","max_tokens":int(os.environ["MAXTOK"]),"messages":[{"role":"user","content":os.environ["PROMPT"]}]}))')"
START="$(python3 -c 'import time;print(time.time())')"
RESP="$(curl -s -m 300 "$BASE/v1/chat/completions" "${AUTH[@]}" -H 'Content-Type: application/json' -d "$REQ")"
END="$(python3 -c 'import time;print(time.time())')"
RESP="$RESP" START="$START" END="$END" MAXTOK="$MAXTOK" python3 -c '
import os, json
data = json.loads(os.environ["RESP"] or "{}")
ct = data.get("usage", {}).get("completion_tokens", int(os.environ["MAXTOK"]))
dur = float(os.environ["END"]) - float(os.environ["START"])
print(f"completion_tokens={ct}  wall={dur:.2f}s  ~{ct/dur:.1f} tok/s" if dur > 0 else "no timing")
'

echo "=== Anthropic /v1/messages (Claude Code wire format) ==="
curl -s -m 300 "$BASE/v1/messages" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"dsv4","max_tokens":64,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}' \
  | head -c 500; echo
