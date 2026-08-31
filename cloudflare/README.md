# The image registry (Cloudflare R2 + Worker)

The all-in-one image is **185 GB**. It is served from a **pull-only OCI registry
backed by Cloudflare R2**, at:

```
dsv4-registry.lukaloehr.com/dsv4-flash-b300:1.0.0
```

Pulling is **public** (no credential) and **not rate-limited**. That is the whole
reason this exists.

## Why not just pull from GHCR?

GHCR throttles its **blob** endpoint with an instantaneous token bucket
(sub-second `retry-after`). A fast, parallel image puller — exactly what RunPod
and containerd use — draws a steady stream of `TOOMANYREQUESTS` from it. We
reproduced this directly against the 185 GB image:

| Where | Endpoint | Requests | 429s |
| :--- | :--- | ---: | ---: |
| Home IP (clean) | `/manifests/…` | 600 | **0** |
| Datacenter IP | `/manifests/…` | 80 | **0** |
| Home IP (clean), authenticated | `/blobs/…` | 318 | **70 (22%)** |
| Datacenter IP, authenticated | `/blobs/…` | 318 | **72 (23%)** |

A clean home IP and a datacenter IP hit the **same** ~22% blob-429 rate, both
authenticated — so it is **not** an IP problem and **not** fixed by a token.
RunPod's puller treats one blob 429 as fatal and restarts the whole pull, so a
185 GB / 53-layer image never converges. (GHCR publishes no pull quota — it is an
unpublished anti-abuse throttle; see the community discussions
[#42479](https://github.com/orgs/community/discussions/42479),
[#139074](https://github.com/orgs/community/discussions/139074).)

R2 has **free egress** and no such blob throttle, so pulling the 185 GB from R2
just works — fast and parallel.

## How it works

```
docker / RunPod
      │  pull dsv4-registry.lukaloehr.com/dsv4-flash-b300:1.0.0
      ▼
Cloudflare Worker  (registry-worker/src/index.js)   ── pull-only OCI /v2 API
      │  GET /v2/<name>/manifests/<ref>   → R2 object manifests/<name>/<ref>
      │  GET /v2/<name>/blobs/<digest>    → R2 object blobs/<digest>  (Range-aware)
      ▼
Cloudflare R2 bucket  dsv4-registry     ── free egress, no blob throttle
      manifests/dsv4-flash-b300/1.0.0
      manifests/dsv4-flash-b300/sha256:…
      blobs/sha256:…                      (config + every layer, content-addressed)
```

The Worker reads R2 through a **binding** — no S3 credential lives at the edge —
and it is **pull-only** (any push verb returns 405). Blobs are content-addressed,
so the image in R2 is bit-identical to the one that was built.

## Tokens (all small-scoped, none committed)

Runtime pulls need **no** token. The only credentials are for the one-time
build/deploy, and each is minimal:

| Token | Scope | Used by | Persistent? |
| :--- | :--- | :--- | :--- |
| Worker deploy | Workers Scripts + Workers R2 Storage (account) | `wrangler deploy` | revocable |
| R2 S3 upload | Object Read & Write on bucket `dsv4-registry` only | `push-to-r2.sh` | revoke after upload |

Both are minted from an admin key with `setup.sh` and printed once; nothing
token-shaped is written into the repo. The custom domain is attached once (see
`setup-domain.sh`) so the deploy token can stay minimal.

## Files

| File | Purpose |
| :--- | :--- |
| [`registry-worker/`](registry-worker/) | The Worker (`wrangler.toml` + `src/index.js`). `wrangler deploy` with the deploy token. |
| [`push-to-r2.sh`](push-to-r2.sh) | Copy an image from any source registry into R2 (streaming, parallel, resumable). |
| [`setup.sh`](setup.sh) | One-time: create the bucket, mint the two small-scoped tokens, deploy the Worker. |
| [`setup-domain.sh`](setup-domain.sh) | One-time: attach `dsv4-registry.lukaloehr.com` to the Worker. |

## Reproduce the whole thing

```bash
# 1. one-time infra (needs an admin API key in the environment; prints the two scoped tokens)
export CLOUDFLARE_API_KEY=…  CLOUDFLARE_EMAIL=…
./setup.sh                       # bucket + tokens + worker
./setup-domain.sh                # custom domain

# 2. copy the image into R2 (run on a box with a fast uplink, e.g. a RunPod pod)
export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…            # the R2 upload token
export R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com
SRC=ghcr.io/luka-loehr/dsv4-flash-b300:1.0.0 NAME=dsv4-flash-b300 TAG=1.0.0 ./push-to-r2.sh

# 3. pull it anywhere, no credential
docker run --gpus all -p 8000:8000 dsv4-registry.lukaloehr.com/dsv4-flash-b300:1.0.0
```
