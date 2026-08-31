#!/usr/bin/env bash
# build-to-r2.sh — build the all-in-one image and publish it to R2. Runs ON a pod
# that has the checkpoint volume mounted. 100% GHCR-free:
#   runtime  = pytorch (Docker Hub) + vLLM (PyPI) + FlashInfer cubins (NVIDIA),
#              built with kaniko (daemonless — RunPod pods block user namespaces
#              so buildah/podman won't run; kaniko does).
#   model    = tarred off the mounted volume as UNCOMPRESSED OCI layers (fast to
#              push AND fast to extract on pull — the weights are already fp8/fp4).
# Both the final image (:VERSION, :latest) and the runtime (:runtime, for shipping
# model updates later without rebuilding vLLM) are uploaded to R2.
#
# Env: R2_ENDPOINT + AWS_ACCESS_KEY_ID/SECRET (bucket-scoped) ; VERSION LAYERS PAR
set -Eeuo pipefail
NAME=dsv4-flash-b300
VERSION="${VERSION:-1.0.0}"
BUCKET="${BUCKET:-dsv4-registry}"
EP="${R2_ENDPOINT:?set R2_ENDPOINT}"
REGDATA="${REGDATA:-/root/regdata}"
STAGE="${STAGE:-/root/stage-tars}"
CTX="${CTX:-/root/ctx}"          # build context: containers/ scripts/ client/
LOCAL="localhost:5000/$NAME"
LAYERS="${LAYERS:-24}"
PAR="${PAR:-10}"
SRC_DIR="${SRC_DIR:-/root}"       # append-layers.go + go.mod live here
export AWS_DEFAULT_REGION=auto PATH="/usr/local/go/bin:$PATH" REGDATA BUCKET EP NAME

echo "== install tools =="
command -v crane >/dev/null 2>&1 || curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz" | tar xz -C /usr/local/bin crane
if ! command -v aws >/dev/null 2>&1; then curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/a.zip; ( cd /tmp && unzip -q -o a.zip && ./aws/install --update >/dev/null 2>&1 ); fi
[ -x /usr/local/go/bin/go ] || command -v go >/dev/null 2>&1 || curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | tar -C /usr/local -xz
command -v registry >/dev/null 2>&1 || curl -fsSL "https://github.com/distribution/distribution/releases/download/v2.8.3/registry_2.8.3_linux_amd64.tar.gz" | tar xz -C /usr/local/bin registry
[ -x /kaniko/executor ] || { mkdir -p /kaniko && crane export gcr.io/kaniko-project/executor:v1.23.2 - | tar -x -C / kaniko; }

echo "== local registry =="
mkdir -p "$REGDATA"
printf 'version: 0.1\nstorage:\n  filesystem:\n    rootdirectory: %s\n  delete:\n    enabled: true\nhttp:\n  addr: 127.0.0.1:5000\n' "$REGDATA" > /root/registry.yml
pkill -f "registry serve" 2>/dev/null || true; sleep 1
nohup registry serve /root/registry.yml >/root/registry.log 2>&1 &
for i in $(seq 1 30); do curl -sf http://127.0.0.1:5000/v2/ >/dev/null 2>&1 && break; sleep 1; done

echo "== build runtime with kaniko (NO GHCR) =="
# kaniko rewrites '/', which would clobber the injected SSH key — guard it.
cp /root/.ssh/authorized_keys /root/ak.bak 2>/dev/null || true
nohup bash -c 'while true; do cp -f /root/ak.bak /root/.ssh/authorized_keys 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null; sleep 2; done' >/dev/null 2>&1 &
GUARD=$!
/kaniko/executor --force --context "$CTX" --dockerfile "$CTX/containers/Dockerfile" \
  --destination "$LOCAL:runtime" --insecure --skip-tls-verify --cleanup=false --snapshot-mode=redo
kill "$GUARD" 2>/dev/null || true
cp -f /root/ak.bak /root/.ssh/authorized_keys 2>/dev/null || true

echo "== build the uncompressed append tool =="
export GOPATH=/root/go GOCACHE=/root/.cache/go-build GOTOOLCHAIN=local GOFLAGS=-mod=mod
BDIR=/root/gobuild; rm -rf "$BDIR"; mkdir -p "$BDIR"; cp "$SRC_DIR/append-layers.go" "$SRC_DIR/go.mod" "$BDIR/"
( cd "$BDIR" && go mod tidy && go build -o /usr/local/bin/dsv4-append append-layers.go )

echo "== append model (uncompressed) onto runtime -> :$VERSION =="
mkdir -p "$STAGE"
INSECURE=1 RUNTIME_IMG="$LOCAL:runtime" FINAL_IMG="$LOCAL" VERSION="$VERSION" \
  MODEL_DIR=/workspace/models/DeepSeek-V4-Flash-0731-abliterated LAYERS="$LAYERS" STAGE="$STAGE" \
  /usr/local/bin/dsv4-append
rm -rf "$STAGE"

# --- publish local image -> R2 (blobs + manifest under BOTH tag and digest) ---
upblob(){
  local d="$1" hex="${1#sha256:}"
  local f="$REGDATA/docker/registry/v2/blobs/sha256/${hex:0:2}/${hex}/data"
  [ -f "$f" ] || { echo "NOFILE $d"; return 1; }
  local sz have got a; sz=$(stat -c%s "$f")
  have=$(aws s3api head-object --bucket "$BUCKET" --key "blobs/$d" --endpoint-url "$EP" --query ContentLength --output text 2>/dev/null||echo "")
  [ "$have" = "$sz" ] && { echo "skip $d"; return 0; }
  for a in 1 2 3 4; do
    if aws s3 cp "$f" "s3://$BUCKET/blobs/$d" --endpoint-url "$EP" --only-show-errors; then
      got=$(aws s3api head-object --bucket "$BUCKET" --key "blobs/$d" --endpoint-url "$EP" --query ContentLength --output text 2>/dev/null||echo "")
      [ "$got" = "$sz" ] && { echo "ok $d"; return 0; }
    fi; sleep $((a*2))
  done; echo "FAIL $d"; return 1
}
export -f upblob
push_image(){ # $1=local-ref  $2=tag  [$3=latest]
  crane manifest "$1" --insecure > /root/mf.json
  python3 -c "import json;m=json.load(open('/root/mf.json'));print(m['config']['digest']);[print(l['digest']) for l in m['layers']]" > /root/dg.txt
  echo "  $2: $(wc -l </root/dg.txt|tr -d ' ') blobs"
  cat /root/dg.txt | xargs -P "$PAR" -I{} bash -c 'upblob "$@"' _ {}
  local MT MD; MT=$(python3 -c "import json;print(json.load(open('/root/mf.json')).get('mediaType','application/vnd.oci.image.manifest.v1+json'))")
  MD="sha256:$(sha256sum /root/mf.json | awk '{print $1}')"
  # store the manifest under the tag AND its digest — RunPod/containerd re-fetch by digest
  aws s3 cp /root/mf.json "s3://$BUCKET/manifests/$NAME/$2" --endpoint-url "$EP" --content-type "$MT" --only-show-errors
  aws s3 cp /root/mf.json "s3://$BUCKET/manifests/$NAME/$MD" --endpoint-url "$EP" --content-type "$MT" --only-show-errors
  [ "${3:-}" = latest ] && aws s3 cp /root/mf.json "s3://$BUCKET/manifests/$NAME/latest" --endpoint-url "$EP" --content-type "$MT" --only-show-errors
}
echo "== publish final image -> R2 (:$VERSION + :latest) =="
push_image "$LOCAL:$VERSION" "$VERSION" latest
echo "== publish runtime image -> R2 (:runtime) =="
push_image "$LOCAL:runtime" "runtime"
echo "BUILD_TO_R2_DONE $NAME:$VERSION"
