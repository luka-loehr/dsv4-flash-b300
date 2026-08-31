# Deploying & building the image

The whole thing is one **self-contained image** — model + vLLM 0.26 + FlashInfer
cubins baked in. Deploying is "pull and run"; there's no volume and no start
command. The image is served from a **Cloudflare R2-backed registry**
(`dsv4-registry.lukaloehr.com`), so the pull is public, needs no credential, and
is not rate-limited.

## Deploy on RunPod

1. **Create the template** (once): `./runpod/create-template.sh`
   (image `dsv4-registry.lukaloehr.com/dsv4-flash-b300:1.0.0`, ports `8000/http`
   + `22/tcp`, 40 GB container disk, no volume). No registry credential needed.
2. **Deploy** on a **B300**:
   ```bash
   runpodctl pod create --template-id <tpl> --gpu-id "NVIDIA B300 SXM6 AC" \
     --data-center-ids EU-NL-1 --ports "8000/http,22/tcp" --container-disk-in-gb 40
   ```
   The image is many layers, so RunPod pulls them **concurrently** from R2.
3. **Read the pod log** (no SSH). The entrypoint serves and prints the endpoint
   `https://<pod-id>-8000.proxy.runpod.net`, the API key, and copy-paste setup for
   every agent CLI.

## Anywhere else

Any host with a Blackwell GPU + Docker:
```bash
docker run --gpus all -p 8000:8000 dsv4-registry.lukaloehr.com/dsv4-flash-b300:1.0.0
```
Bump `max-concurrent-downloads` in `/etc/docker/daemon.json` to parallelize the pull.

## Why a custom registry (and not GHCR)

GHCR throttles its **blob** endpoint with an instantaneous token bucket
(sub-second `retry-after`). A fast parallel puller — which is what RunPod and
containerd use — draws a steady ~22% of `TOOMANYREQUESTS` from it, reproducibly,
from any IP, authenticated or not; RunPod's puller treats one blob 429 as fatal
and restarts the whole pull, so a 185 GB image never converges. R2 has free
egress and no such throttle. Full write-up and reproduction: [`cloudflare/README.md`](../cloudflare/README.md).

## Rebuilding & publishing the image (rare) — 100% GHCR-free

One pod with the checkpoint volume mounted does the whole thing —
[`ops/build-on-runpod.sh`](../ops/build-on-runpod.sh) spins it and runs
[`ops/build-to-r2.sh`](../ops/build-to-r2.sh) on it, which:

1. **Builds the runtime** from [`containers/Dockerfile`](../containers/Dockerfile)
   with **kaniko** (daemonless — RunPod pods block user namespaces, so
   buildah/podman can't run). The base comes from Docker Hub, vLLM from PyPI, the
   FlashInfer cubins from NVIDIA — **nothing is pulled from GHCR**.
2. **Appends the model** off the mounted volume as **uncompressed OCI tar layers**
   ([`ops/append-layers.go`](../ops/append-layers.go)) — no gzip, so it pushes fast
   and, crucially, *extracts* fast on pull (a plain `untar`, not a single-threaded
   gzip inflate).
3. **Publishes to R2** (blobs + each manifest under **both its tag and its digest**,
   since RunPod/containerd re-fetch the manifest by digest): the final image
   `:VERSION` + `:latest`, and the `:runtime` image on its own — so a model refresh
   can reuse the runtime without rebuilding vLLM.

Publishing uses only the bucket-scoped R2 upload credential; no pull token, no GHCR.
The R2 registry itself is set up once with [`cloudflare/setup.sh`](../cloudflare/setup.sh)
and [`cloudflare/setup-domain.sh`](../cloudflare/setup-domain.sh).
