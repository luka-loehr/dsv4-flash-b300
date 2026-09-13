# DeepSeek-V4-Flash Architecture & B300 Serving Stack

This document details the architectural characteristics, quantization schemes, and runtime execution graph of `DeepSeek-V4-Flash-0731-abliterated` on a single NVIDIA B300 (Blackwell `sm_103a`).

---

## 1. High-Level Serving Pipeline

```text
               ┌────────────────────────────────────────────────────────┐
               │              macOS Client: Claude Code                 │
               │         `cc-dsv4` (Anthropic Messages Wire)            │
               └───────────────────────────┬────────────────────────────┘
                                           │ HTTPS (RunPod Proxy)
                                           ▼
               ┌────────────────────────────────────────────────────────┐
               │           vLLM 0.26.0 (HTTP API Server)                │
               │   Anthropic Messages ↔ OpenAI Chat Completions Engine  │
               └───────────────────────────┬────────────────────────────┘
                                           │ Shared Memory / IPC
                                           ▼
               ┌────────────────────────────────────────────────────────┐
               │              vLLM V1 EngineCore Worker                 │
               │  ├── Prefix Caching (256-token block granularity)      │
               │  ├── Attention: FLASHINFER_MLA_SPARSE_DSV4             │
               │  ├── Dense GEMM: DeepGEMM Block-Scaled FP8 (UE8M0)     │
               │  ├── MoE Routing: FlashInfer TRTLLM-GEN MXFP4/MXFP8    │
               │  └── Speculative: DSpark-7 (Markov Head Decoders)      │
               └───────────────────────────┬────────────────────────────┘
                                           │ CUDA Graphs (Full + Piecewise)
                                           ▼
               ┌────────────────────────────────────────────────────────┐
               │          NVIDIA B300 SXM6 AC (275 GB HBM3e)            │
               │              sm_103a · 8.0 TB/s Memory Bandwidth       │
               └────────────────────────────────────────────────────────┘
```

---

## 2. Quantization Scheme

The 156 GB native checkpoint uses a hybrid dual-precision quantization strategy optimized for Blackwell tensor cores:

* **Dense Linear Layers**:
  * Precision: **Block-128 FP8** (`e4m3fn`) with UE8M0 scaling factors.
  * Kernel Engine: `DeepGEMM` with Programmatic Dependent Launch (PDL) and warp-specialized matrix multiplication.
* **MoE Feed-Forward Experts**:
  * Precision: **Block-32 Packed FP4** (`e2m1`) with FP8 scales.
  * Kernel Engine: `FlashInfer TRTLLM-GEN` MoE fused routing and GEMM kernels compiled directly for `sm_103a`.
* **Attention Mechanism (Sparse MLA)**:
  * Key/Value Cache: **FP8** (`e4m3fn`) matrix-scaled Multi-Head Latent Attention.
  * Indexer: **FP4** Lightning Indexer cache for ultra-fast top-$k$ attention routing across 128k context.
* **Multi-Head Compressor (MHC)**:
  * Precision: `bfloat16` fused with RMSNorm via TileLang JIT-compiled kernels.

---

## 3. Speculative Decoding Pipeline (DSpark-7)

Rather than traditional autoregressive generation (1 token per forward step) or generic Multi-Token Prediction (MTP), this deployment uses **DSpark** with 3 internal draft layers and Markov prediction heads:

1. **Draft Generation**: For each step, the 3 DSpark draft layers (`mtp.0`, `mtp.1`, `mtp.2`) generate up to 7 speculative candidate tokens.
2. **Markov Head Guidance**: A rank-256 low-rank Markov transition head guides candidate selection based on token adjacency statistics.
3. **Verification**: The full 156 GB base model verifies all 7 candidate tokens in a single parallel forward pass.
4. **Throughput**: Mean acceptance length is **3.79 tokens**; measured single-stream output throughput is about **276 tok/s** (see [PERFORMANCE.md](PERFORMANCE.md)).

---

## 4. Deployment Path

```text
MacBook (macOS)
  │  cc-dsv4  →  Claude Code CLI
  │  ANTHROPIC_BASE_URL = https://<pod-id>-8000.proxy.runpod.net
  ▼
RunPod HTTPS proxy (port 8000)
  ▼
vLLM 0.26.0  ──  native Anthropic Messages API  (/v1/messages, drop-in for Claude Code)
  ├── Tokenizer:        deepseek_v4
  ├── Attention:        FlashInfer MLA (TRTLLM-GEN), FP8 DS-MLA + FP4 Lightning-Indexer cache
  ├── Speculation:      DSpark-7 — mtp.{0,1,2} draft weights + rank-256 Markov head
  ├── MoE:              FlashInfer TRTLLM-GEN MXFP4 / MXFP8
  └── Dense MM:         DeepGEMM block-scaled FP8 (UE8M0)
  ▼
DeepSeek-V4-Flash-0731 Abliterated  ·  156 GB checkpoint baked into the image
  ▼
1× NVIDIA B300 SXM6 AC (275 GB HBM3e @ 8.0 TB/s)
```

The image is served from a Cloudflare R2-backed registry (see
[cloudflare/README.md](../cloudflare/README.md)) and is built without GHCR: the
runtime comes from Docker Hub (pytorch), PyPI (vLLM) and NVIDIA (cubins), the model
is tarred off the volume as uncompressed layers, and both are uploaded to R2
([RUNPOD-TEMPLATE.md](RUNPOD-TEMPLATE.md)). Claude Code speaks the Anthropic
Messages API; vLLM 0.26 serves `/v1/messages` natively alongside the OpenAI routes,
so no translation proxy is involved.
