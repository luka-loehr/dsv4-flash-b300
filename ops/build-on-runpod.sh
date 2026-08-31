#!/usr/bin/env bash
# build-on-runpod.sh — build & publish the all-in-one image, only when you need
# to update it (rarely). Spins a RunPod pod that mounts the checkpoint volume,
# builds the image locally off the volume (no model download), and uploads it
# straight to R2 with ops/build-to-r2.sh, then deletes the pod.
#
# Prereqs:
#   • runpodctl configured (runpodctl doctor)
#   • a network volume that holds the checkpoint at /workspace/models/<name>
#   • the runtime image built by CI (.github/workflows/publish-runtime-image.yml)
#   • R2 upload creds (bucket-scoped) + the R2 S3 endpoint
#
# Usage:
#   VERSION=1.0.0 VOLUME_ID=<vol> DATACENTER=EU-NL-1 \
#   R2_ENDPOINT=https://<acct>.r2.cloudflarestorage.com \
#   AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
#   ops/build-on-runpod.sh
set -Eeuo pipefail

VERSION="${VERSION:?set VERSION}"; VOLUME_ID="${VOLUME_ID:?set VOLUME_ID}"
DATACENTER="${DATACENTER:-EU-NL-1}"
: "${R2_ENDPOINT:?set R2_ENDPOINT}"; : "${AWS_ACCESS_KEY_ID:?}"; : "${AWS_SECRET_ACCESS_KEY:?}"
GPU="${GPU_ID:-NVIDIA B300 SXM6 AC}"
KEY="${RUNPOD_SSH_KEY:-$HOME/.ssh/runpod_ed25519}"
PUBKEY="${RUNPOD_SSH_PUBKEY:-$HOME/.ssh/runpod_ed25519.pub}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o IdentitiesOnly=yes"

# A GPU pod is used only for its large container disk: the image is built into a
# local registry on disk (~180 GB) before the fast R2 upload.
echo "==> creating build pod (volume $VOLUME_ID, 300 GB disk)"
ENVJSON=$(python3 -c "import json,sys;print(json.dumps({'PUBLIC_KEY':open('$PUBKEY').read().strip()}))")
runpodctl pod create --name dsv4-image-build \
  --image runpod/pytorch:1.0.3-cu1300-torch291-ubuntu2404 \
  --gpu-id "$GPU" --gpu-count 1 \
  --data-center-ids "$DATACENTER" --network-volume-id "$VOLUME_ID" \
  --container-disk-in-gb 300 --ports "22/tcp" --env "$ENVJSON" >/dev/null

# resolve ssh once the container is up
for i in $(seq 1 40); do
  INFO=$(runpodctl ssh info dsv4-image-build 2>/dev/null || true)
  echo "$INFO" | grep -q ssh_command && break; sleep 6
done
PID=$(runpodctl pod list 2>/dev/null | python3 -c "import sys,json;print([p['id'] for p in json.load(sys.stdin) if p.get('name')=='dsv4-image-build'][0])")
IP=$(echo "$INFO" | python3 -c "import sys,json;print(json.load(sys.stdin)['ip'])")
PORT=$(echo "$INFO" | python3 -c "import sys,json;print(json.load(sys.stdin)['port'])")
echo "    pod $PID at $IP:$PORT"
trap 'echo "==> deleting pod $PID"; runpodctl remove pod "$PID" >/dev/null 2>&1 || true' EXIT

echo "==> uploading build files"
# shellcheck disable=SC2086
scp -i "$KEY" -P "$PORT" $SO "$HERE/append-layers.go" "$HERE/go.mod" "$HERE/build-to-r2.sh" "root@$IP:/root/"
echo "==> building off the volume and uploading to R2"
# shellcheck disable=SC2086
ssh -i "$KEY" -p "$PORT" $SO "root@$IP" \
  "AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' R2_ENDPOINT='$R2_ENDPOINT' VERSION='$VERSION' bash /root/build-to-r2.sh"

echo "==> done: dsv4-registry.lukaloehr.com/dsv4-flash-b300:${VERSION} (+ :latest)"
