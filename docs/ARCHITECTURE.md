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
4. **Throughput**: Achieves a **3.79 token mean acceptance length**, multiplying decoding throughput to **366.6 tok/s**.
