#!/usr/bin/env bash
# setup.sh — one-time Cloudflare infra for the R2-backed registry:
#   1. create the R2 bucket
#   2. mint two SMALL-SCOPED tokens (worker-deploy, r2-s3-upload) and print them
#   3. deploy the Worker with the deploy token
#
# Nothing token-shaped is written into the repo — the two tokens are printed once;
# save them in your secret manager. Runtime pulls need no token at all.
#
# Env: CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL  (admin global key, used only to mint
#      the scoped tokens and create the bucket).
set -Eeuo pipefail

BUCKET="${BUCKET:-dsv4-registry}"
LOCATION="${R2_LOCATION:-weur}"
WORKER_DIR="$(cd "$(dirname "$0")/registry-worker" && pwd)"
API="https://api.cloudflare.com/client/v4"
AUTH=(-H "X-Auth-Email: ${CLOUDFLARE_EMAIL:?set CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_API_KEY:?set CLOUDFLARE_API_KEY}")

ACC=$(curl -s "$API/accounts" "${AUTH[@]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'][0]['id'])")
echo "account=$ACC  bucket=$BUCKET"

echo "== 1. create bucket (idempotent) =="
curl -s -X POST "$API/accounts/$ACC/r2/buckets" "${AUTH[@]}" -H "Content-Type: application/json" \
  -d "{\"name\":\"$BUCKET\",\"locationHint\":\"$LOCATION\"}" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('created' if d.get('success') else d['errors'][0]['message'])"

echo "== 2. mint scoped tokens =="
# permission-group ids are resolved live so this works on any account
PG=$(curl -s "$API/user/tokens/permission_groups" "${AUTH[@]}")
gid() { echo "$PG" | python3 -c "import sys,json;n='$1';print(next(g['id'] for g in json.load(sys.stdin)['result'] if g['name']==n))"; }
G_SCRIPTS=$(gid "Workers Scripts Write")
G_R2W=$(gid "Workers R2 Storage Write"); G_R2R=$(gid "Workers R2 Storage Read")
G_ACCT=$(gid "Account Settings Read")
G_ITEMR=$(gid "Workers R2 Storage Bucket Item Read"); G_ITEMW=$(gid "Workers R2 Storage Bucket Item Write")

mint() { # $1=name  $2=json-policies
  curl -s -X POST "$API/user/tokens" "${AUTH[@]}" -H "Content-Type: application/json" \
    -d "{\"name\":\"$1\",\"policies\":$2}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result']['id']+' '+d['result']['value'] if d.get('success') else 'ERR '+str(d['errors']))"
}
ACC_RES="{\"com.cloudflare.api.account.$ACC\":\"*\"}"
BKT_RES="{\"com.cloudflare.edge.r2.bucket.${ACC}_default_${BUCKET}\":\"*\"}"

DEPLOY=$(mint "dsv4-wrangler-deploy" "[{\"effect\":\"allow\",\"resources\":$ACC_RES,\"permission_groups\":[{\"id\":\"$G_SCRIPTS\"},{\"id\":\"$G_R2W\"},{\"id\":\"$G_R2R\"},{\"id\":\"$G_ACCT\"}]}]")
UPLOAD=$(mint "dsv4-r2-upload" "[{\"effect\":\"allow\",\"resources\":$BKT_RES,\"permission_groups\":[{\"id\":\"$G_ITEMR\"},{\"id\":\"$G_ITEMW\"}]}]")

DEPLOY_TOKEN=${DEPLOY#* }
UPLOAD_ID=${UPLOAD%% *}; UPLOAD_VAL=${UPLOAD#* }
UPLOAD_SECRET=$(printf %s "$UPLOAD_VAL" | shasum -a 256 | awk '{print $1}')

cat <<EOF

  SAVE THESE (printed once) — do not commit:
  ── Worker deploy token (CLOUDFLARE_API_TOKEN for wrangler):
     $DEPLOY_TOKEN
  ── R2 S3 upload credentials (for push-to-r2.sh / aws):
     AWS_ACCESS_KEY_ID=$UPLOAD_ID
     AWS_SECRET_ACCESS_KEY=$UPLOAD_SECRET
     R2_ENDPOINT=https://$ACC.r2.cloudflarestorage.com

EOF

echo "== 3. deploy the Worker =="
CLOUDFLARE_API_TOKEN="$DEPLOY_TOKEN" CLOUDFLARE_ACCOUNT_ID="$ACC" \
  wrangler deploy --cwd "$WORKER_DIR" 2>&1 | tail -6 || \
  ( cd "$WORKER_DIR" && CLOUDFLARE_API_TOKEN="$DEPLOY_TOKEN" CLOUDFLARE_ACCOUNT_ID="$ACC" wrangler deploy 2>&1 | tail -6 )

echo "Next: ./setup-domain.sh   then   ./push-to-r2.sh"
