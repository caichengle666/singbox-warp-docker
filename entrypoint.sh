#!/usr/bin/env bash
set -euo pipefail

WGCF_DIR="/var/lib/wgcf"
SB_TEMPLATE="/etc/sing-box/template.json"
SB_CONFIG="/etc/sing-box/config.json"
HY2_PORT_ENV="${HY2_PORT:-32443}"
VLESS_PORT_ENV="${VLESS_PORT:-38443}"
AUTO_TLS_ENV="${AUTO_TLS:-false}"
TLS_DOMAIN_ENV="${TLS_DOMAIN:-}"
ACME_EMAIL_ENV="${ACME_EMAIL:-}"
TLS_ISSUE_RETRIES_ENV="${TLS_ISSUE_RETRIES:-3}"
TLS_RENEW_INTERVAL_ENV="${TLS_RENEW_INTERVAL:-43200}"
AUTH_UUID_ENV="${AUTH_UUID:-}"
HY2_PASSWORD_ENV="${HY2_PASSWORD:-}"
VLESS_UUID_ENV="${VLESS_UUID:-}"
SINGBOX_PID=""

ensure_tls_cert() {
  mkdir -p /etc/sing-box/certs /var/lib/acme
  export HOME=/var/lib/acme
  export LE_CONFIG_HOME=/var/lib/acme/.acme.sh
  export CF_Token="${CF_Token:-}"
  export CF_Account_ID="${CF_Account_ID:-}"
  export CF_Zone_ID="${CF_Zone_ID:-}"

  if [ "$AUTO_TLS_ENV" != "true" ]; then
    return 0
  fi

  if [ -z "$TLS_DOMAIN_ENV" ]; then
    echo "[tls] AUTO_TLS=true but TLS_DOMAIN is empty"
    exit 1
  fi

  if [ -z "$CF_Token" ]; then
    echo "[tls] AUTO_TLS=true requires CF_Token for dns_cf"
    exit 1
  fi

  if [ -n "$ACME_EMAIL_ENV" ]; then
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    /root/.acme.sh/acme.sh --register-account -m "$ACME_EMAIL_ENV" --server letsencrypt >/dev/null 2>&1 || true
  fi

  if [ ! -s "/etc/sing-box/certs/fullchain.pem" ] || [ ! -s "/etc/sing-box/certs/privkey.pem" ]; then
    echo "[tls] issuing cert for $TLS_DOMAIN_ENV"
    i=1
    while [ "$i" -le "$TLS_ISSUE_RETRIES_ENV" ]; do
      if /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$TLS_DOMAIN_ENV" --keylength ec-256 --server letsencrypt; then
        break
      fi
      if [ "$i" -eq "$TLS_ISSUE_RETRIES_ENV" ]; then
        echo "[tls] issue failed after $TLS_ISSUE_RETRIES_ENV attempts"
        exit 1
      fi
      echo "[tls] issue failed, retrying ($i/$TLS_ISSUE_RETRIES_ENV) in 5s"
      sleep 5
      i=$((i + 1))
    done
    /root/.acme.sh/acme.sh --install-cert -d "$TLS_DOMAIN_ENV" --ecc \
      --fullchain-file /etc/sing-box/certs/fullchain.pem \
      --key-file /etc/sing-box/certs/privkey.pem
  else
    echo "[tls] existing cert found, checking renewal"
    before_sum="$(sha256sum /etc/sing-box/certs/fullchain.pem /etc/sing-box/certs/privkey.pem 2>/dev/null | sha256sum | awk '{print $1}')"
    /root/.acme.sh/acme.sh --renew -d "$TLS_DOMAIN_ENV" --ecc --server letsencrypt || true
    /root/.acme.sh/acme.sh --install-cert -d "$TLS_DOMAIN_ENV" --ecc \
      --fullchain-file /etc/sing-box/certs/fullchain.pem \
      --key-file /etc/sing-box/certs/privkey.pem
    after_sum="$(sha256sum /etc/sing-box/certs/fullchain.pem /etc/sing-box/certs/privkey.pem 2>/dev/null | sha256sum | awk '{print $1}')"
    if [ "$before_sum" != "$after_sum" ]; then
      echo "[tls] cert updated during startup renewal check"
    fi
  fi
}

renew_tls_cert_if_needed() {
  if [ "$AUTO_TLS_ENV" != "true" ]; then
    return 0
  fi

  if [ ! -s "/etc/sing-box/certs/fullchain.pem" ] || [ ! -s "/etc/sing-box/certs/privkey.pem" ]; then
    echo "[tls] cert files missing, running full ensure"
    ensure_tls_cert
    return 0
  fi

  before_sum="$(sha256sum /etc/sing-box/certs/fullchain.pem /etc/sing-box/certs/privkey.pem 2>/dev/null | sha256sum | awk '{print $1}')"
  /root/.acme.sh/acme.sh --renew -d "$TLS_DOMAIN_ENV" --ecc --server letsencrypt || true
  /root/.acme.sh/acme.sh --install-cert -d "$TLS_DOMAIN_ENV" --ecc \
    --fullchain-file /etc/sing-box/certs/fullchain.pem \
    --key-file /etc/sing-box/certs/privkey.pem
  after_sum="$(sha256sum /etc/sing-box/certs/fullchain.pem /etc/sing-box/certs/privkey.pem 2>/dev/null | sha256sum | awk '{print $1}')"

  if [ "$before_sum" != "$after_sum" ]; then
    echo "[tls] cert changed, reloading sing-box"
    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
      kill -HUP "$SINGBOX_PID" || true
    fi
  fi
}

start_singbox() {
  echo "[sing-box] starting"
  sing-box run -c "$SB_CONFIG" &
  SINGBOX_PID="$!"
}

mkdir -p "$WGCF_DIR" /etc/sing-box
cd "$WGCF_DIR"
ensure_tls_cert

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

if [ -z "$AUTH_UUID_ENV" ]; then
  AUTH_UUID_ENV="$(cat /proc/sys/kernel/random/uuid)"
fi
if [ -z "$HY2_PASSWORD_ENV" ]; then
  HY2_PASSWORD_ENV="$AUTH_UUID_ENV"
fi
if [ -z "$VLESS_UUID_ENV" ]; then
  VLESS_UUID_ENV="$AUTH_UUID_ENV"
fi

sed -i \
  -e "s|__WARP_PRIVATE_KEY__|$WARP_PRIVATE_KEY|g" \
  -e "s|__WARP_ADDRESS_V4__|$WARP_ADDRESS_V4|g" \
  -e "s|__WARP_ADDRESS_V6__|$WARP_ADDRESS_V6|g" \
  -e "s|__WARP_PEER_PUBLIC_KEY__|$WARP_PEER_PUBLIC_KEY|g" \
  -e "s|__WARP_PEER_HOST__|$WARP_PEER_HOST|g" \
  -e "s|__WARP_PEER_PORT__|$WARP_PEER_PORT|g" \
  -e "s|__HY2_PORT__|$HY2_PORT_ENV|g" \
  -e "s|__VLESS_PORT__|$VLESS_PORT_ENV|g" \
  -e "s|__HY2_PASSWORD__|$HY2_PASSWORD_ENV|g" \
  -e "s|__VLESS_UUID__|$VLESS_UUID_ENV|g" \
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

start_singbox

while true; do
  if ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
    echo "[sing-box] process exited"
    exit 1
  fi

  sleep "$TLS_RENEW_INTERVAL_ENV"
  renew_tls_cert_if_needed
done
