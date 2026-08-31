#!/usr/bin/env bash
# push-to-r2.sh — copy an OCI image from a source registry into the R2 bucket
# that backs dsv4-registry. Streams each blob (crane blob → aws s3 cp), no disk
# staging, in parallel, and is resumable (skips blobs already present with the
# right size). Blobs are content-addressed, so a re-run is safe.
#
# Env:
#   SRC          source image, e.g. ghcr.io/luka-loehr/dsv4-flash-b300:1.0.0
#   NAME         target repo path in the new registry, e.g. dsv4-flash-b300
#   TAG          target tag, e.g. 1.0.0
#   R2_ENDPOINT  https://<account_id>.r2.cloudflarestorage.com
#   BUCKET       R2 bucket (default dsv4-registry)
#   PAR          parallel blobs (default 6)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   R2 S3 creds (bucket-scoped)
set -Eeuo pipefail

SRC="${SRC:?set SRC=ghcr.io/owner/repo:tag}"
NAME="${NAME:?set NAME=target/repo/path}"
TAG="${TAG:?set TAG=tag}"
BUCKET="${BUCKET:-dsv4-registry}"
EP="${R2_ENDPOINT:?set R2_ENDPOINT}"
PAR="${PAR:-6}"
REPO="${SRC%:*}"
WORK="${WORK:-/tmp/r2push}"; mkdir -p "$WORK"
export AWS_DEFAULT_REGION=auto

echo "== install crane + aws (if missing) =="
command -v crane >/dev/null 2>&1 || curl -fsSL \
  "https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz" \
  | tar xz -C /usr/local/bin crane
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$WORK/awscli.zip"
  ( cd "$WORK" && unzip -q -o awscli.zip && ./aws/install --update >/dev/null 2>&1 )
fi
crane version 2>/dev/null || true; aws --version

echo "== fetch manifest =="
crane manifest "$SRC" > "$WORK/manifest.json"
python3 - "$WORK/manifest.json" > "$WORK/blobs.tsv" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
rows = [(m["config"]["digest"], m["config"]["size"])]
rows += [(l["digest"], l["size"]) for l in m["layers"]]
for d, s in rows:
    print(f"{d}\t{s}")
PY
TOTAL=$(python3 -c "import sys;print(sum(int(l.split(chr(9))[1]) for l in open('$WORK/blobs.tsv')))")
echo "blobs: $(wc -l < "$WORK/blobs.tsv" | tr -d ' ')  total: $(python3 -c "print(round($TOTAL/1e9,1))") GB"

RHOST="${REPO%%/*}"        # ghcr.io
RPATH="${REPO#*/}"         # luka-loehr/dsv4-flash-b300
export EP BUCKET REPO WORK RHOST RPATH

# Copy one blob from the source registry into R2, reliably.
#   download  : curl -C - to a local file. crane does NOT retry GHCR's blob 429,
#               and streaming over a pipe corrupts R2's multipart when the source
#               drops, so we pull to disk: --retry-all-errors absorbs the 429 and
#               -C - RESUMES a partial file across retries and mid-stream drops.
#   upload    : aws s3 cp of the complete, size-checked file (file-based multipart
#               is deterministic on R2). Needs ~one blob of scratch per parallel
#               slot, so run this on a pod with a scratch volume for PAR>1.
copyblob() {
  local line="$1"
  local d="${line%%$'\t'*}"
  local size="${line##*$'\t'}"
  local key="blobs/$d"
  local have
  have=$(aws s3api head-object --bucket "$BUCKET" --key "$key" --endpoint-url "$EP" \
          --query ContentLength --output text 2>/dev/null || echo "")
  if [ "$have" = "$size" ]; then echo "skip  $d ($size)"; return 0; fi
  local f="$WORK/${d#sha256:}.blob"
  local a fsz got tok
  for a in 1 2 3 4 5 6 7 8; do
    # Fresh full download each attempt. NO -C - resume: on a non-range (200)
    # response it would append a second copy and overshoot `size`. curl's own
    # --retry absorbs GHCR's 429 and, with -o (not -C -), truncates on each
    # internal retry, so the file can never exceed `size`. We then verify the
    # EXACT size before uploading, so a corrupt/partial blob never reaches R2.
    rm -f "$f"
    tok=$(curl -s "https://${RHOST}/token?service=${RHOST}&scope=repository:${RPATH}:pull" \
          | sed 's/.*"token":"//;s/".*//')
    curl -sL --fail --retry 30 --retry-all-errors --retry-delay 2 \
      -H "Authorization: Bearer $tok" -o "$f" \
      "https://${RHOST}/v2/${RPATH}/blobs/${d}" || true
    fsz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$fsz" != "$size" ]; then echo "dl       $d ${fsz}/${size} (retry $a)"; sleep $((a * 2)); continue; fi
    # upload the exact-size file; aws overwrites any corrupt object already in R2
    if aws s3 cp "$f" "s3://$BUCKET/$key" --endpoint-url "$EP" --only-show-errors; then
      got=$(aws s3api head-object --bucket "$BUCKET" --key "$key" --endpoint-url "$EP" \
             --query ContentLength --output text 2>/dev/null || echo "")
      if [ "$got" = "$size" ]; then rm -f "$f"; echo "ok    $d ($size)"; return 0; fi
      echo "up-bad   $d got=$got want=$size (retry $a)"
    else
      echo "up-err   $d (retry $a)"
    fi
    sleep $((a * 2))
  done
  rm -f "$f"; echo "FAIL  $d"; return 1
}
export -f copyblob

echo "== stream $((PAR)) blobs in parallel =="
rc=0
while IFS= read -r line; do printf '%s\0' "$line"; done < "$WORK/blobs.tsv" \
  | xargs -0 -P "$PAR" -I{} bash -c 'copyblob "$@"' _ {} || rc=1

if [ "$rc" != 0 ]; then echo "some blobs failed — re-run to resume"; exit 1; fi

echo "== store manifest under tag + digest =="
MT=$(python3 -c "import json;print(json.load(open('$WORK/manifest.json')).get('mediaType','application/vnd.oci.image.manifest.v1+json'))")
MD="sha256:$(sha256sum "$WORK/manifest.json" | awk '{print $1}')"
aws s3 cp "$WORK/manifest.json" "s3://$BUCKET/manifests/$NAME/$TAG" --endpoint-url "$EP" --content-type "$MT" --only-show-errors
aws s3 cp "$WORK/manifest.json" "s3://$BUCKET/manifests/$NAME/$MD"  --endpoint-url "$EP" --content-type "$MT" --only-show-errors
echo "PUSH_DONE $NAME:$TAG  manifest=$MD  registry-blobs=$BUCKET"
