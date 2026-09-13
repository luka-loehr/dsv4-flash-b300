# Performance, boot time and cost

## Measured performance

Tested live on a single NVIDIA B300 SXM6 AC (275 GB HBM3e @ 8.0 TB/s):

| Metric | Measured value | Notes |
| :--- | :---: | :--- |
| Context window | 1,048,576 tokens (1M) | DeepSeek-V4 native position embeddings (config) |
| Max generation | 131,072 tokens (128k) | Per-request generation cap (config) |
| Output throughput | ≈276 tok/s | Single-stream, warm shape, 700-token generation (verified 2026-08-31) |
| Short-gen throughput | ≈130–160 tok/s | ≤200-token replies; lower because TTFT is a larger share |
| First-token latency (TTFT) | ~60 ms | Warm shape, short prompt |
| Speculative mean acceptance | 3.79 tokens | DSpark-7 (`draft_sample_method: probabilistic`), via `bench.sh` |
| Draft acceptance | pos-1 81.1% · overall 39.9% | Multi-layer Markov-head draft modules, via `bench.sh` |
| Cached prefill | 5,853.9 tok/s | FlashInfer DS-MLA with prefix caching, via `bench.sh` |
| KV cache capacity | 2,978,316 tokens | FP8 KV (79.3 GB, 2.84× concurrent 1M ctx) |

Throughput varies with speculative-decode acceptance, which depends on the prompt.
The rows marked *via `bench.sh`* come from [`scripts/bench.sh`](../scripts/bench.sh);
the throughput/TTFT rows were re-verified live on 2026-08-31.

## Boot time

Nothing is pulled from a model hub, but a fresh B300 is not instant. Measured
end-to-end, deploy to first `/health` 200 took about 69 minutes (single fresh pod,
2026-08-31). The phases:

1. **Pull** ~185 GB from R2, measured at up to 15 Gbit/s.
2. **Extract** the layers to the container disk. This is disk-write-bound (a few
   hundred MB/s on RunPod's overlay) and is the largest single phase (30+ min for
   156 GB). Layers ship uncompressed (plain `tar`, no gzip), so there is no inflate
   pass, but the disk write dominates. This comes with baking a 156 GB model into
   an image; a network volume would trade it for a mount.
3. **Load weights into HBM**, about 9 min (measured 528 s for 157 GiB).
4. **First-serve JIT compile**, 20+ min the first time. vLLM/FlashInfer fetch the
   remaining `batched_gemm` cubin headers from NVIDIA and compile the MoE,
   attention, TileLang and DeepGEMM kernels with `ptxas` on demand (one
   `batched_gemm` compile alone took ~10 min), then autotune the FP4 MoE kernel.
   The cubin prefetch baked into the image is partial (NVIDIA's artifactory
   throttles a full bake), so the remaining shapes are fetched and compiled here.

After boot, new request shapes still compile once. The first request at a new
context-size bucket triggers a synchronous kernel compile and drops to single-digit
tok/s for that turn, then runs at full speed (~276 tok/s). A CLI with a large system
prompt and tools (e.g. Pi) hits a couple of these on its first turns.

### Roadmap

Two changes would remove most of phase 4 and the runtime stalls:

- a resumable, untimed cubin prefetch at build time, so nothing is fetched at runtime;
- warming every shape bucket during the image build (representative prompts so all
  `mhc_*`/DeepGEMM/TileLang/`batched_gemm` kernels compile), then baking the JIT cache.

That would reduce cold start to pull, extract and the ~9 min HBM load.

## Cost

You pay for the B300 while it runs, including the pull and extract on each fresh
pod. Stop the pod to release GPU billing. RunPod caches images per host, so a
stop/start of the same pod skips the pull and extract, but a new pod may land on a
different host and pull again.
