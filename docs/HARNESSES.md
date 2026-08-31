# Agent CLI compatibility

vLLM serves **two wire APIs at the same endpoint**:

- **Anthropic Messages API** — `https://<pod-id>-8000.proxy.runpod.net/v1/messages` (Claude Code)
- **OpenAI API** — `https://<pod-id>-8000.proxy.runpod.net/v1/chat/completions` (everything else)

So any terminal coding agent that speaks either protocol works. The served model
name is **`dsv4`**.

## Your API key

Every pod gets its **own** key — generated on boot and printed (with the endpoint
URL) in the pod log, or set your own with `-e DSV4_API_KEY=…`. Use it as the
Bearer token for OpenAI calls and as `ANTHROPIC_AUTH_TOKEN` for Claude Code.

## One-time setup

```bash
./client/install.sh    # stores pod URL + key in ~/.config/dsv4/env, installs launchers
```

The launchers all read `~/.config/dsv4/env`:

```bash
export DSV4_POD_URL="https://<pod-id>-8000.proxy.runpod.net"
export DSV4_API_KEY="sk-dsv4-…"
```

Override per run: `DSV4_POD_URL=https://<new-pod-id>-8000.proxy.runpod.net cc-dsv4`.

---

## Claude Code — `cc-dsv4`

Uses the Anthropic Messages API directly (no proxy).

```bash
cc-dsv4                       # or: cc-dsv4 -p "explain src/main.rs"
```
Sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and maps Opus/Sonnet/Haiku to `dsv4`.

## Codex CLI — `codex-dsv4`

Points Codex at a custom provider via `-c` overrides — no edits to your
`~/.codex/config.toml`:

```bash
codex-dsv4 exec "…"           # wraps: codex -c model=dsv4 -c model_provider=dsv4 \
                              #   -c model_providers.dsv4.base_url=<pod>/v1 \
                              #   -c model_providers.dsv4.env_key=DSV4_API_KEY \
                              #   -c model_providers.dsv4.wire_api=responses
```

Modern Codex (>= ~0.140) only speaks the **OpenAI Responses API** (`wire_api=chat`
was removed), which vLLM serves at `<pod>/v1/responses`. Codex prints a harmless
`failed to refresh available models` warning (its model-list probe expects a
different shape than vLLM's standard `/v1/models`); the completion itself works.

## Pi — `pi-dsv4`

Pi has no base-URL flag or env var — it reads providers from `~/.pi/agent/models.json`.
The launcher upserts a `dsv4` provider there (keeping your other providers) with the
current URL + key, then runs Pi against it:

```bash
pi-dsv4 -p "…"                # wraps: pi --provider dsv4 --model dsv4/dsv4
```

## OpenCode — `opencode-dsv4`

Writes a dedicated OpenCode config (`~/.config/dsv4/opencode.json`, never touches
your global one) with an `@ai-sdk/openai-compatible` provider, then runs OpenCode:

```bash
opencode-dsv4
```

## Aider — `aider-dsv4`

```bash
aider-dsv4                    # wraps: OPENAI_API_BASE=<pod>/v1 aider --model openai/dsv4
```

## Any other OpenAI-compatible tool

Point it at the base URL and key directly:

```bash
export OPENAI_BASE_URL="https://<pod-id>-8000.proxy.runpod.net/v1"
export OPENAI_API_KEY="<your key>"
# model: dsv4
```

Verify the endpoint yourself:

```bash
curl -s $OPENAI_BASE_URL/models -H "Authorization: Bearer $OPENAI_API_KEY"
curl -s $OPENAI_BASE_URL/chat/completions -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"dsv4","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

---

## Validation

All five launchers were exercised end-to-end against a mock server speaking both
the OpenAI and Anthropic APIs (with SSE streaming): each CLI connects, sends a
well-formed request to the right route (`cc-dsv4` → `/v1/messages`, `codex-dsv4`
→ `/v1/responses`, `pi-dsv4` / `opencode-dsv4` / `aider-dsv4` → `/v1/chat/completions`),
and renders the reply. The wire formats are exactly what vLLM serves.
