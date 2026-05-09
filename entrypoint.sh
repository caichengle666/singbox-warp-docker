#!/usr/bin/env bash
set -euo pipefail

WGCF_DIR="/var/lib/wgcf"
SB_TEMPLATE="/etc/sing-box/template.json"
SB_CONFIG="/etc/sing-box/config.json"
HY2_PORT_ENV="${HY2_PORT:-32443}"
VLESS_PORT_ENV="${VLESS_PORT:-38443}"

mkdir -p "$WGCF_DIR" /etc/sing-box
cd "$WGCF_DIR"

if [ ! -f "$WGCF_DIR/wgcf-account.toml" ]; then
  if [ -f /etc/wgcf/account.toml ] && [ -s /etc/wgcf/account.toml ]; then
    cp /etc/wgcf/account.toml "$WGCF_DIR/wgcf-account.toml"
  fi
fi

if [ ! -f "$WGCF_DIR/wgcf-account.toml" ]; then
  echo "[warp] no account found, registering new account"
  wgcf register --accept-tos
else
  echo "[warp] using existing account"
fi

if [ ! -f "$WGCF_DIR/wgcf-profile.conf" ]; then
  echo "[warp] generating profile"
  wgcf generate
fi

profile="$WGCF_DIR/wgcf-profile.conf"

WARP_PRIVATE_KEY="$(awk -F' = ' '/^PrivateKey/{print $2}' "$profile" | tr -d '[:space:]')"
WARP_ADDRESS_V4="$(awk -F' = ' '/^Address/{print $2}' "$profile" | awk -F', ' '{print $1}' | tr -d '[:space:]')"
WARP_ADDRESS_V6="$(awk -F' = ' '/^Address/{print $2}' "$profile" | awk -F', ' '{print $2}' | tr -d '[:space:]')"
WARP_PEER_PUBLIC_KEY="$(awk -F' = ' '/^PublicKey/{print $2}' "$profile" | tr -d '[:space:]' | head -n1)"
WARP_PEER_ENDPOINT="$(awk -F' = ' '/^Endpoint/{print $2}' "$profile" | tr -d '[:space:]')"
WARP_PEER_HOST="${WARP_PEER_ENDPOINT%%:*}"
WARP_PEER_PORT="${WARP_PEER_ENDPOINT##*:}"

if [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_ADDRESS_V4" ] || [ -z "$WARP_PEER_PUBLIC_KEY" ] || [ -z "$WARP_PEER_HOST" ] || [ -z "$WARP_PEER_PORT" ]; then
  echo "[warp] failed to parse wgcf profile"
  exit 1
fi

cp "$SB_TEMPLATE" "$SB_CONFIG"

sed -i \
  -e "s|__WARP_PRIVATE_KEY__|$WARP_PRIVATE_KEY|g" \
  -e "s|__WARP_ADDRESS_V4__|$WARP_ADDRESS_V4|g" \
  -e "s|__WARP_ADDRESS_V6__|$WARP_ADDRESS_V6|g" \
  -e "s|__WARP_PEER_PUBLIC_KEY__|$WARP_PEER_PUBLIC_KEY|g" \
  -e "s|__WARP_PEER_HOST__|$WARP_PEER_HOST|g" \
  -e "s|__WARP_PEER_PORT__|$WARP_PEER_PORT|g" \
  -e "s|__HY2_PORT__|$HY2_PORT_ENV|g" \
  -e "s|__VLESS_PORT__|$VLESS_PORT_ENV|g" \
  "$SB_CONFIG"

jq empty "$SB_CONFIG" >/dev/null

HY2_PASSWORD="$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$SB_CONFIG" | head -n1)"
HY2_PORT="$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$SB_CONFIG" | head -n1)"
HY2_SNI="$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tls.server_name // empty' "$SB_CONFIG" | head -n1)"
HY2_INSECURE="$(jq -r '.inbounds[] | select(.type=="hysteria2") | if .tls.insecure then 1 else 0 end' "$SB_CONFIG" | head -n1)"
HY2_TAG="$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tag // "hy2"' "$SB_CONFIG" | head -n1)"

if [ -n "$HY2_PASSWORD" ] && [ -n "$HY2_PORT" ] && [ -n "$HY2_SNI" ]; then
  HY2_LINK="hy2://${HY2_PASSWORD}@${HY2_SNI}:${HY2_PORT}?sni=${HY2_SNI}&insecure=${HY2_INSECURE}#${HY2_TAG}"
  echo "[node] $HY2_LINK"
else
  echo "[node] skipped: unable to build hy2 link from config"
fi

VLESS_UUID="$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$SB_CONFIG" | head -n1)"
VLESS_PORT="$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$SB_CONFIG" | head -n1)"
VLESS_SNI="$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name // empty' "$SB_CONFIG" | head -n1)"
VLESS_TAG="$(jq -r '.inbounds[] | select(.type=="vless") | .tag // "vless"' "$SB_CONFIG" | head -n1)"

if [ -n "$VLESS_UUID" ] && [ -n "$VLESS_PORT" ] && [ -n "$VLESS_SNI" ]; then
  VLESS_LINK="vless://${VLESS_UUID}@${VLESS_SNI}:${VLESS_PORT}?encryption=none&security=tls&sni=${VLESS_SNI}&type=tcp#${VLESS_TAG}"
  echo "[node] $VLESS_LINK"
else
  echo "[node] skipped: unable to build vless link from config"
fi

echo "[sing-box] starting"
exec sing-box run -c "$SB_CONFIG"
