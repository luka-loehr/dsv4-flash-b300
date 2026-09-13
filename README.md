![dsv4-flash-b300 banner](docs/assets/banner.png)

# dsv4-flash-b300 – DeepSeek-V4-Flash on one NVIDIA B300

[![vLLM](https://img.shields.io/badge/vLLM-0.26.0-blue?style=flat)](https://vllm.ai) [![CUDA](https://img.shields.io/badge/CUDA-13.0-76B900?style=flat&logo=nvidia&logoColor=white)](https://developer.nvidia.com/cuda-toolkit) [![Platform](https://img.shields.io/badge/Platform-RunPod%20%C2%B7%20NVIDIA%20B300-76B900?style=flat&logo=nvidia&logoColor=white)](docs/RUNPOD-TEMPLATE.md) [![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?style=flat&logo=anthropic&logoColor=white)](docs/CLAUDE-CODE.md) [![License](https://img.shields.io/badge/License-MIT-orange?style=flat)](LICENSE)

**dsv4-flash-b300** is a self-contained serving image for [`prem-research/DeepSeek-V4-Flash-0731-abliterated`](https://huggingface.co/prem-research/DeepSeek-V4-Flash-0731-abliterated) on a single NVIDIA B300. It bundles the checkpoint, vLLM 0.26 and FlashInfer kernels, and serves the Anthropic and OpenAI APIs so Claude Code, Codex, Pi, OpenCode and Aider can connect directly.

> **Abliterated model.** Safety refusals were removed upstream. You are solely responsible for how you use it and for complying with applicable laws and the terms of any provider involved (e.g. RunPod, Anthropic, OpenAI). See [docs/MODEL.md](docs/MODEL.md).

---

## Features

- **One image** with the 156 GB checkpoint, vLLM runtime and FlashInfer cubins; no volume or start command
- **Two APIs** on one endpoint: Anthropic `/v1/messages` and OpenAI `/v1/chat/completions`
- **Agent CLI launchers** for Claude Code, Codex, Pi, OpenCode and Aider (`client/install.sh`)
- **DSpark-7 speculative decoding** with FP8 KV cache, ~276 tok/s single-stream measured
- **1M-token context**, up to 128k tokens per generation
- **Public R2-backed registry** that avoids GHCR blob throttling; no pull credential
- **Per-pod API key** generated on boot, or set with `DSV4_API_KEY`

A fresh pod takes about 69 minutes to its first healthy response (image pull and extract, weight load, first-serve kernel compile). See [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

---

## Quick start

```bash
# RunPod: create the template once, then deploy it on a B300
./runpod/create-template.sh
runpodctl pod create --template-id <id> --gpu-id "NVIDIA B300 SXM6 AC" \
  --data-center-ids EU-NL-1 --ports "8000/http,22/tcp" --container-disk-in-gb 40

# Any other Blackwell host with Docker
docker run --gpus all -p 8000:8000 dsv4-registry.lukaloehr.com/dsv4-flash-b300:1.0.0

# On your Mac: enter the pod URL and API key from the pod log
./client/install.sh && cc-dsv4
```

To use your own registry, set `REGISTRY=<host>` for `runpod/create-template.sh` (see [docs/RUNPOD-TEMPLATE.md](docs/RUNPOD-TEMPLATE.md#using-your-own-registry)).

---

## Documentation

- [RunPod template, deploy and image build](docs/RUNPOD-TEMPLATE.md)
- [Performance, boot time and cost](docs/PERFORMANCE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Model, quantization and license](docs/MODEL.md)
- [Scripts](docs/SCRIPTS.md)
- [Agent CLI setup](docs/HARNESSES.md) and [Claude Code specifics](docs/CLAUDE-CODE.md)
- [Speculative decoding](docs/SPECULATIVE-DECODING.md) and [attention and kernels](docs/ATTENTION-AND-KERNELS.md)
- [Runbook](docs/RUNBOOK.md) and [R2 image registry](cloudflare/README.md)

---

## License

MIT - [View License](LICENSE)  
The image redistributes the upstream MIT-licensed [DeepSeek-V4-Flash-0731-abliterated](https://huggingface.co/prem-research/DeepSeek-V4-Flash-0731-abliterated) weights under their original license; see [docs/MODEL.md](docs/MODEL.md#license-and-credits).

---

## Support

- [Report bugs](https://github.com/luka-loehr/dsv4-flash-b300/issues)  
- [luka@lukaloehr.com](mailto:luka@lukaloehr.com)  

---

Developed by [Luka Löhr](https://github.com/luka-loehr)
