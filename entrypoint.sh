#!/usr/bin/env bash
set -euo pipefail

WGCF_DIR="/var/lib/wgcf"
SB_TEMPLATE="/etc/sing-box/template.json"
SB_CONFIG="/etc/sing-box/config.json"
SINGBOX_PID_FILE="/run/sing-box.pid"
HY2_PORT_ENV="${HY2_PORT:-32443}"
VLESS_PORT_ENV="${VLESS_PORT:-38443}"
AUTO_TLS_ENV="${AUTO_TLS:-false}"
TLS_DOMAIN_ENV="${TLS_DOMAIN:-}"
ACME_EMAIL_ENV="${ACME_EMAIL:-}"
TLS_ISSUE_RETRIES_ENV="${TLS_ISSUE_RETRIES:-3}"
TLS_RENEW_INTERVAL_ENV="${TLS_RENEW_INTERVAL:-43200}"
TLS_CERT_PATH_ENV="${TLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}"
TLS_KEY_PATH_ENV="${TLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}"
WARP_LICENSE_KEY_ENV="${WARP_LICENSE_KEY:-}"
AUTH_UUID_ENV="${AUTH_UUID:-}"
HY2_PASSWORD_ENV="${HY2_PASSWORD:-}"
VLESS_UUID_ENV="${VLESS_UUID:-}"
SINGBOX_PID=""
STOP_REQUESTED="false"

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "[config] $name must be a positive integer, got: $value"
    exit 1
  fi
}

renew_tls_cert_once() {
  local mode="$1"

  if /root/.acme.sh/acme.sh --renew -d "$TLS_DOMAIN_ENV" --ecc --server letsencrypt; then
    echo "[tls] renewal check succeeded during $mode"
    /root/.acme.sh/acme.sh --install-cert -d "$TLS_DOMAIN_ENV" --ecc \
      --fullchain-file "$TLS_CERT_PATH_ENV" \
      --key-file "$TLS_KEY_PATH_ENV"
    return 0
  fi

  echo "[tls] renewal check did not update cert during $mode"
  return 1
}

ensure_tls_cert() {
  mkdir -p "$(dirname "$TLS_CERT_PATH_ENV")" "$(dirname "$TLS_KEY_PATH_ENV")" /var/lib/acme
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

  if [ ! -s "$TLS_CERT_PATH_ENV" ] || [ ! -s "$TLS_KEY_PATH_ENV" ]; then
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
      --fullchain-file "$TLS_CERT_PATH_ENV" \
      --key-file "$TLS_KEY_PATH_ENV"
  else
    echo "[tls] existing cert found, checking renewal"
    before_sum="$(sha256sum "$TLS_CERT_PATH_ENV" "$TLS_KEY_PATH_ENV" 2>/dev/null | sha256sum | awk '{print $1}')"
    renew_tls_cert_once "startup" || true
    after_sum="$(sha256sum "$TLS_CERT_PATH_ENV" "$TLS_KEY_PATH_ENV" 2>/dev/null | sha256sum | awk '{print $1}')"
    if [ "$before_sum" != "$after_sum" ]; then
      echo "[tls] cert updated during startup renewal check"
    fi
  fi
}

renew_tls_cert_if_needed() {
  if [ "$AUTO_TLS_ENV" != "true" ]; then
    return 0
  fi

  if [ ! -s "$TLS_CERT_PATH_ENV" ] || [ ! -s "$TLS_KEY_PATH_ENV" ]; then
    echo "[tls] cert files missing, running full ensure"
    ensure_tls_cert
    return 0
  fi

  before_sum="$(sha256sum "$TLS_CERT_PATH_ENV" "$TLS_KEY_PATH_ENV" 2>/dev/null | sha256sum | awk '{print $1}')"
  renew_tls_cert_once "runtime" || true
  after_sum="$(sha256sum "$TLS_CERT_PATH_ENV" "$TLS_KEY_PATH_ENV" 2>/dev/null | sha256sum | awk '{print $1}')"

  if [ "$before_sum" != "$after_sum" ]; then
    echo "[tls] cert changed, reloading sing-box"
    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
      kill -HUP "$SINGBOX_PID" || true
    fi
  fi
}

stop_singbox() {
  if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
    echo "[sing-box] stopping"
    kill -TERM "$SINGBOX_PID" 2>/dev/null || true
    wait "$SINGBOX_PID" 2>/dev/null || true
  fi
  rm -f "$SINGBOX_PID_FILE"
}

handle_signal() {
  STOP_REQUESTED="true"
  stop_singbox
  exit 0
}

start_singbox() {
  echo "[sing-box] starting"
  sing-box run -c "$SB_CONFIG" &
  SINGBOX_PID="$!"
  printf '%s\n' "$SINGBOX_PID" > "$SINGBOX_PID_FILE"
}

validate_required_config() {
  validate_positive_integer "TLS_ISSUE_RETRIES" "$TLS_ISSUE_RETRIES_ENV"
  validate_positive_integer "TLS_RENEW_INTERVAL" "$TLS_RENEW_INTERVAL_ENV"
  validate_positive_integer "HY2_PORT" "$HY2_PORT_ENV"
  validate_positive_integer "VLESS_PORT" "$VLESS_PORT_ENV"

  if [ "$AUTO_TLS_ENV" = "true" ] && [ -z "$TLS_DOMAIN_ENV" ]; then
    echo "[config] TLS_DOMAIN is required when AUTO_TLS=true"
    exit 1
  fi

  if [ "$AUTO_TLS_ENV" != "true" ]; then
    if [ ! -s "$TLS_CERT_PATH_ENV" ]; then
      echo "[config] manual TLS cert file missing: $TLS_CERT_PATH_ENV"
      exit 1
    fi
    if [ ! -s "$TLS_KEY_PATH_ENV" ]; then
      echo "[config] manual TLS key file missing: $TLS_KEY_PATH_ENV"
      exit 1
    fi
  fi
}

mkdir -p "$WGCF_DIR" /etc/sing-box
cd "$WGCF_DIR"
validate_required_config
ensure_tls_cert

if [ ! -f "$WGCF_DIR/wgcf-account.toml" ]; then
  echo "[warp] no account found, registering new account"
  wgcf register --accept-tos
else
  echo "[warp] using existing account"
fi

PROFILE_NEEDS_REGEN="false"
if [ -n "$WARP_LICENSE_KEY_ENV" ]; then
  current_warp_license_key="$(awk -F' = ' '/^license_key/{print $2}' "$WGCF_DIR/wgcf-account.toml" | tr -d '"[:space:]' | head -n1)"
  if [ "$current_warp_license_key" != "$WARP_LICENSE_KEY_ENV" ]; then
    echo "[warp] applying WARP license key update"
    wgcf update --license-key "$WARP_LICENSE_KEY_ENV"
    PROFILE_NEEDS_REGEN="true"
  else
    echo "[warp] existing license key already matches"
  fi
fi

if [ ! -f "$WGCF_DIR/wgcf-profile.conf" ] || [ "$PROFILE_NEEDS_REGEN" = "true" ]; then
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
  -e "s|__HY2_PORT__|$HY2_PORT_ENV|g" \
  -e "s|__VLESS_PORT__|$VLESS_PORT_ENV|g" \
  -e "s|__WARP_PEER_PORT__|$WARP_PEER_PORT|g" \
  "$SB_CONFIG"

tmp_config="$(mktemp)"
jq \
  --arg hy2Password "$HY2_PASSWORD_ENV" \
  --arg vlessUuid "$VLESS_UUID_ENV" \
  --arg tlsDomain "$TLS_DOMAIN_ENV" \
  --arg tlsCertPath "$TLS_CERT_PATH_ENV" \
  --arg tlsKeyPath "$TLS_KEY_PATH_ENV" \
  --arg warpPrivateKey "$WARP_PRIVATE_KEY" \
  --arg warpAddressV4 "$WARP_ADDRESS_V4" \
  --arg warpAddressV6 "$WARP_ADDRESS_V6" \
  --arg warpPeerPublicKey "$WARP_PEER_PUBLIC_KEY" \
  --arg warpPeerHost "$WARP_PEER_HOST" \
  '
  (.inbounds[] | select(.type=="hysteria2") | .users[0].password) = $hy2Password |
  (.inbounds[] | select(.type=="vless") | .users[0].uuid) = $vlessUuid |
  (.inbounds[] | .tls.server_name) = $tlsDomain |
  (.inbounds[] | .tls.certificate_path) = $tlsCertPath |
  (.inbounds[] | .tls.key_path) = $tlsKeyPath |
  (.endpoints[] | select(.tag=="warp") | .address) = [$warpAddressV4, $warpAddressV6] |
  (.endpoints[] | select(.tag=="warp") | .private_key) = $warpPrivateKey |
  (.endpoints[] | select(.tag=="warp") | .peers[0].address) = $warpPeerHost |
  (.endpoints[] | select(.tag=="warp") | .peers[0].public_key) = $warpPeerPublicKey
  ' \
  "$SB_CONFIG" > "$tmp_config"
mv "$tmp_config" "$SB_CONFIG"

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

trap handle_signal TERM INT HUP

while true; do
  if [ "$STOP_REQUESTED" = "true" ]; then
    exit 0
  fi

  if ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
    echo "[sing-box] process exited"
    wait "$SINGBOX_PID" || true
    exit 1
  fi

  sleep "$TLS_RENEW_INTERVAL_ENV"
  renew_tls_cert_if_needed
done
