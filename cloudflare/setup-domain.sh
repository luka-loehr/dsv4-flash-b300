#!/usr/bin/env bash
# setup-domain.sh — attach the custom domain dsv4-registry.lukaloehr.com to the
# Worker. One-time admin action (needs Workers Routes + DNS), which is why it is
# separate from the deploy token — that token stays minimal.
#
# Env: CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL (admin global key), or CF_API_TOKEN
#      with Workers Routes:Edit + DNS:Edit + Zone:Read on the zone.
set -Eeuo pipefail

HOSTNAME_="${REGISTRY_HOST:-dsv4-registry.lukaloehr.com}"
ZONE_NAME="${ZONE_NAME:-lukaloehr.com}"
SERVICE="${WORKER_NAME:-dsv4-registry}"
API="https://api.cloudflare.com/client/v4"

if [ -n "${CF_API_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer $CF_API_TOKEN")
else
  AUTH=(-H "X-Auth-Email: ${CLOUDFLARE_EMAIL:?set CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_API_KEY:?set CLOUDFLARE_API_KEY}")
fi

ACC=$(curl -s "$API/accounts" "${AUTH[@]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'][0]['id'])")
ZONE=$(curl -s "$API/zones?name=$ZONE_NAME" "${AUTH[@]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'][0]['id'])")
echo "account=$ACC zone=$ZONE host=$HOSTNAME_ -> worker=$SERVICE"

curl -s -X PUT "$API/accounts/$ACC/workers/domains" "${AUTH[@]}" -H "Content-Type: application/json" \
  -d "{\"zone_id\":\"$ZONE\",\"hostname\":\"$HOSTNAME_\",\"service\":\"$SERVICE\",\"environment\":\"production\"}" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('OK' if d.get('success') else d.get('errors'))"
echo "Done. Test: curl -s https://$HOSTNAME_/v2/"
