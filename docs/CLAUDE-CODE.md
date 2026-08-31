# Claude Code Integration Guide

This guide describes how to connect the native macOS Claude Code CLI to the self-hosted DeepSeek-V4-Flash backend on RunPod.

---

## 1. Quick Setup

```bash
# 1. Install cc-dsv4 locally
./client/install-mac.sh

# 2. Run Claude Code
cc-dsv4
```

---

## 2. Environment Variables Configured by `cc-dsv4`

| Variable | Value | Purpose |
| :--- | :--- | :--- |
| `ANTHROPIC_BASE_URL` | `https://<pod-id>-8000.proxy.runpod.net` | Bare host (no trailing `/v1`) |
| `ANTHROPIC_API_KEY` | *(Secret from `~/.config/cc-dsv4/env`)* | Authenticates against vLLM API key |
| `ANTHROPIC_AUTH_TOKEN`| *(Secret from `~/.config/cc-dsv4/env`)* | Passed in headers for Anthropic wire compatibility |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `dsv4` | Routes Opus requests to DeepSeek-V4 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL`| `dsv4` | Routes Sonnet requests to DeepSeek-V4 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `dsv4` | Routes Haiku requests to DeepSeek-V4 |
| `ANTHROPIC_MODEL` | `dsv4` | Primary model identifier |
| `ENABLE_TOOL_SEARCH` | `true` | Enables tool search on self-hosted endpoints |

---

## 3. Passing CLI Arguments

All flags are passed directly through to `claude`:
```bash
# Non-interactive prompt:
cc-dsv4 -p "Refactor the auth middleware in src/auth.rs"

# Custom directory:
cc-dsv4 --dir ~/Documents/my-project
```
