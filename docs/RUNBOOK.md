# Daily Operations & Troubleshooting Runbook

---

## 1. Starting the Server

### Fast / Production Mode (Recommended)
```bash
/workspace/scripts/bootstrap-runtime.sh && /workspace/scripts/start-vllm.sh fast
```
* Includes: DSpark-7, FlashInfer MLA, FP4 Lightning Indexer cache, DeepGEMM MoE, full CUDA graphs.
* Decode Speed: **~366.6 tok/s**.

### Safe / Diagnostic Mode
```bash
/workspace/scripts/bootstrap-runtime.sh && /workspace/scripts/start-vllm.sh safe
```
* Standard baseline without speculative decoding or aggressive CUDA graphs.

---

## 2. Stopping the Server

```bash
/workspace/scripts/stop-vllm.sh
```
* Sends `SIGTERM` to vLLM, waits for graceful exit, falls back to `SIGKILL` if needed, and validates that `nvidia-smi` reports **0 MiB** used VRAM.

---

## 3. Checking Server Health

```bash
/workspace/scripts/health-check.sh
```
Outputs:
* GPU VRAM utilization and temperature.
* Running vLLM / EngineCore processes.
* Port 8000 `/health` HTTP status.
* Model list from `/v1/models`.

---

## 4. Running Throughput Benchmarks

```bash
/workspace/scripts/bench.sh
```
Measures:
* Single-stream streaming throughput (tok/s).
* Time to First Token (TTFT).
* DSpark speculative acceptance statistics.
* Anthropic Messages endpoint verification.
