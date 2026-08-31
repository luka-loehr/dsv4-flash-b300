# Attention Backends & Kernel Optimization

This document documents the critical attention kernel bugs encountered on Blackwell and their resolution.

---

## 1. The `FlashMLA` SM100 Assertion Failure

### Symptom
When serving multi-turn chat sessions with varying prompt prefix lengths, the vLLM EngineCore worker crashed with:
```text
RuntimeError: Assertion error (/workspace/.deps/flashmla-src/csrc/sm100/prefill/sparse/fwd/head64/instantiations/../phase1.cuh:651): Assertion `res == CUresult::CUDA_SUCCESS` failed.
```

### Cause
On NVIDIA B300 (which reports Compute Capability 10.3 / `sm_103a`), vLLM's automatic backend selector defaulted to `FlashMLA` (a port of Hopper SM90 kernels). On non-power-of-two chunked prefill lengths, FlashMLA's phase-1 CUDA kernel fails internal synchronization.

### Fix
Explicitly select FlashInfer's native TensorRT-LLM sparse MLA backend:
```bash
--attention-backend FLASHINFER_MLA_SPARSE_DSV4
```
This routes sparse MLA through FlashInfer's Blackwell-native `trtllm_sparse_mla` kernels, resolving the crash.

---

## 2. TileLang Multi-Head Compressor (MHC) Warmup

DeepSeek-V4 uses a Multi-Head Compressor layer (`mhc_pre`, `mhc_post`, `hc_head`) compiled via TileLang.

* **Behavior**: When encountering an un-warmed sequence shape, TileLang performs a JIT compilation (~8 seconds).
* **Caching**: Once compiled, TileLang writes the compiled binary into `/root/.cache/cuda/` and `/root/.cache/vllm/`.
* **Block Caching Interaction**: When Prefix Caching is enabled with `--block-size 256`, existing prompt blocks are reused without re-entering the compressor, achieving **> 5,800 tokens/s prompt prefill speed**.

---

## 3. FlashInfer TRTLLM-GEN MoE AutoTuner

FlashInfer includes an automatic micro-benchmarking tuner for the FP4 block-scale MoE router.

* On first launch, the AutoTuner profiles 9 distinct kernel configurations on the GPU to identify the optimal GEMM tile schedule.
* Results are cached to `/root/.cache/vllm/flashinfer_autotune_cache/.../autotune_configs.json`.
* Subsequent boots read this JSON in < 1ms, skipping all tuning steps.
