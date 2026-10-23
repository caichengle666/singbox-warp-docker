#!/usr/bin/env bash
# Render config/sing-box.template.json with valid dummy values and run
# `sing-box check` on it, so a sing-box release that rejects the template
# fails CI before an image is pushed.
# Usage: scripts/check-template.sh [path-to-sing-box-binary]
set -euo pipefail

SING_BOX="${1:-sing-box}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/config/sing-box.template.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$work/privkey.pem" -out "$work/fullchain.pem" -days 1 \
  -subj "/CN=example.com" >/dev/null 2>&1

wg_private="$("$SING_BOX" generate wg-keypair | sed -n 's/^PrivateKey: //p')"
wg_peer_public="$("$SING_BOX" generate wg-keypair | sed -n 's/^PublicKey: //p')"
ss_password="$("$SING_BOX" generate rand --base64 32)"
[ -n "$wg_private" ] && [ -n "$wg_peer_public" ] && [ -n "$ss_password" ]

rendered="$(cat "$template")"
rendered="${rendered//__HY2_PORT__/32443}"
rendered="${rendered//__VLESS_PORT__/38443}"
rendered="${rendered//__ANYTLS_PORT__/4443}"
rendered="${rendered//__SS_PORT__/48443}"
rendered="${rendered//__MIXED_PORT__/1080}"
rendered="${rendered//__HY2_TAG__/hy2-test}"
rendered="${rendered//__VLESS_TAG__/vless-test}"
rendered="${rendered//__HY2_PASSWORD__/dummy_hy2_password}"
rendered="${rendered//__VLESS_UUID__/11111111-1111-1111-1111-111111111111}"
rendered="${rendered//__ANYTLS_PASSWORD__/dummy_anytls_password}"
rendered="${rendered//__SS_PASSWORD__/$ss_password}"
rendered="${rendered//__TLS_DOMAIN__/example.com}"
rendered="${rendered//__TLS_CERT_PATH__/$work/fullchain.pem}"
rendered="${rendered//__TLS_KEY_PATH__/$work/privkey.pem}"
rendered="${rendered//__WARP_PEER_PORT__/2408}"
rendered="${rendered//__WARP_PEER_HOST__/engage.cloudflareclient.com}"
rendered="${rendered//__WARP_ADDRESS_V4__/172.16.0.2/32}"
rendered="${rendered//__WARP_ADDRESS_V6__/2606:4700:110:8765::2/128}"
rendered="${rendered//__WARP_PRIVATE_KEY__/$wg_private}"
rendered="${rendered//__WARP_PEER_PUBLIC_KEY__/$wg_peer_public}"

if grep -q '__[A-Z0-9_]*__' <<<"$rendered"; then
  echo "unrendered placeholders left in template:" >&2
  grep -o '__[A-Z0-9_]*__' <<<"$rendered" | sort -u >&2
  exit 1
fi

printf '%s\n' "$rendered" > "$work/config.json"
jq empty "$work/config.json"
"$SING_BOX" check -c "$work/config.json"

# Each route the entrypoint can switch to must also pass.
for outbound in direct warp usque; do
  jq --arg outbound "$outbound" '.route.final = $outbound' \
    "$work/config.json" > "$work/route-$outbound.json"
  "$SING_BOX" check -c "$work/route-$outbound.json"
done

echo "sing-box template check passed ($("$SING_BOX" version | head -n1))"
