#!/usr/bin/env bash
# create-template.sh — create the RunPod template that runs the all-in-one image.
# No volume, no start command, and NO registry credential: the image is served
# from a public, un-rate-limited Cloudflare R2 registry, and the image's own
# entrypoint serves and prints the endpoint + API key to the pod log.
#
# Usage:  ./runpod/create-template.sh
set -euo pipefail

REGISTRY="${REGISTRY:-dsv4-registry.lukaloehr.com}"
VERSION="${VERSION:-1.0.0}"
IMAGE="${REGISTRY}/dsv4-flash-b300:${VERSION}"

READ_ME="MIT by Luka Löhr. All-in-one: DeepSeek-V4-Flash-0731 (abliterated) + vLLM 0.26 + FlashInfer cubins baked into the image — pull and run on one NVIDIA B300, ZERO downloads, no volume. Serves the Anthropic + OpenAI APIs (Claude Code, Codex, Pi, OpenCode, Aider); prints the endpoint + API key to the pod log. The ~185 GB image is served from a Cloudflare R2 registry and the pull is PUBLIC and not rate-limited — no registry credential needed. Source: https://github.com/luka-loehr/dsv4-flash-b300"

echo "Creating RunPod template for $IMAGE"
runpodctl template create \
  --name "DeepSeek-V4-Flash B300 (all-in-one)" \
  --image "$IMAGE" \
  --container-disk-in-gb 40 \
  --ports "8000/http,22/tcp" \
  --port-labels "8000=vllm,22=ssh" \
  --env '{"DSV4_PROFILE":"fast"}' \
  --readme "$READ_ME"

echo
echo "Deploy it on a B300 — no registry credential required:"
echo "  runpodctl pod create --template-id <id> --gpu-id 'NVIDIA B300 SXM6 AC' \\"
echo "    --data-center-ids EU-NL-1 --ports '8000/http,22/tcp' --container-disk-in-gb 40"
