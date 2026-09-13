# Scripts

| File | Purpose |
| :--- | :--- |
| [`containers/Dockerfile`](../containers/Dockerfile) | Runtime layer: vLLM 0.26 + FlashInfer cubins + scripts + entrypoint (built with kaniko by `ops/build-to-r2.sh`). |
| [`containers/entrypoint.sh`](../containers/entrypoint.sh) | Image entrypoint: SSH, API key, start vLLM, print endpoint. |
| [`ops/build-to-r2.sh`](../ops/build-to-r2.sh) · [`ops/build-on-runpod.sh`](../ops/build-on-runpod.sh) | Build the all-in-one image from the mounted checkpoint volume and upload it to R2. |
| [`cloudflare/`](../cloudflare/README.md) | The R2-backed registry that serves the image: Worker, R2 push, one-time setup. |
| [`runpod/create-template.sh`](../runpod/create-template.sh) | Create the RunPod template for the image (`REGISTRY`, `VERSION` overridable). |
| [`scripts/start-vllm.sh`](../scripts/start-vllm.sh) `fast\|safe` | Start vLLM. `fast` = DSpark-7 + FP4 indexer + CUDA graphs; `safe` = diagnostic. |
| [`scripts/stop-vllm.sh`](../scripts/stop-vllm.sh) · [`health-check.sh`](../scripts/health-check.sh) · [`bench.sh`](../scripts/bench.sh) | Stop, status, and single-stream benchmark. |
| [`client/install.sh`](../client/install.sh) | Install the Mac launchers (`cc-dsv4`, `codex-dsv4`, `pi-dsv4`, `opencode-dsv4`, `aider-dsv4`). |
