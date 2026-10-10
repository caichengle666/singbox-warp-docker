#!/usr/bin/env bash
set -euo pipefail

WGCF_DIR="/var/lib/wgcf"
SB_TEMPLATE="/etc/sing-box/template.json"
SB_CONFIG="/etc/sing-box/config.json"
SINGBOX_PID_FILE="/run/sing-box.pid"
HY2_PORT_ENV="${HY2_PORT:-32443}"
VLESS_PORT_ENV="${VLESS_PORT:-38443}"
ANYTLS_PORT_ENV="${ANYTLS_PORT:-4443}"
SS_PORT_ENV="${SS_PORT:-48443}"
ENABLE_HY2_ENV="${ENABLE_HY2:-true}"
ENABLE_VLESS_ENV="${ENABLE_VLESS:-true}"
ENABLE_ANYTLS_ENV="${ENABLE_ANYTLS:-false}"
ENABLE_SS_ENV="${ENABLE_SS:-false}"
MIXED_PORT_ENV="${MIXED_PORT:-1080}"
AUTO_TLS_ENV="${AUTO_TLS:-false}"
TLS_DOMAIN_ENV="${TLS_DOMAIN:-}"
ACME_EMAIL_ENV="${ACME_EMAIL:-}"
TLS_ISSUE_RETRIES_ENV="${TLS_ISSUE_RETRIES:-3}"
TLS_RENEW_INTERVAL_ENV="${TLS_RENEW_INTERVAL:-43200}"
TLS_CERT_PATH_ENV="${TLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}"
TLS_KEY_PATH_ENV="${TLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}"
WARP_MODE_ENV="${WARP_MODE:-auto}"
WARP_AUTORECOVER_ENV="${WARP_AUTORECOVER:-true}"
WARP_PROBE_INTERVAL_ENV="${WARP_PROBE_INTERVAL:-60}"
USQUE_HTTP2_ENV="${USQUE_HTTP2:-true}"
WARP_LICENSE_KEY_ENV="${WARP_LICENSE_KEY:-}"
AUTH_UUID_ENV="${AUTH_UUID:-}"
HY2_PASSWORD_ENV="${HY2_PASSWORD:-}"
VLESS_UUID_ENV="${VLESS_UUID:-}"
ANYTLS_PASSWORD_ENV="${ANYTLS_PASSWORD:-}"
SS_PASSWORD_ENV="${SS_PASSWORD:-}"
NODE_NAME_ENV="${NODE_NAME:-}"
SINGBOX_PID=""
STOP_REQUESTED="false"
PROCESS_CHECK_INTERVAL_SECONDS=10
WARP_MONITOR_PID=""
WARP_ROUTE_STATE_FILE="/run/warp-route.state"
WARP_PROBE_PORT=18080
USQUE_PORT=18081
USQUE_CONFIG="${WGCF_DIR}/usque-config.json"
USQUE_PID_FILE="/run/usque.pid"
CREDENTIALS_FILE="${WGCF_DIR}/credentials.env"
USQUE_REGISTER_STAMP="${WGCF_DIR}/.usque-register-last"
USQUE_REGISTER_MIN_INTERVAL=3600
USQUE_READY_TIMEOUT=10
WARP_FAIL_THRESHOLD=3
WARP_FAIL_RECHECK_INTERVAL=10
WARP_RETRY_MAX_INTERVAL=900
HY2_PORT_HOPPING_ENV="${HY2_PORT_HOPPING:-false}"
HY2_HOP_PORTS_ENV="${HY2_HOP_PORTS:-}"
WARP_PROBE_URLS=(
  "https://api.ipify.org"
  "https://www.cloudflare.com/cdn-cgi/trace"
  "https://api64.ipify.org?format=json"
)

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "[config] $name must be a positive integer, got: $value"
    exit 1
  fi
}

validate_port() {
  local name="$1"
  local value="$2"
  validate_positive_integer "$name" "$value"
  if (( 10#$value > 65535 )); then
    echo "[config] $name must be between 1 and 65535, got: $value"
    exit 1
  fi
}

retry_command() {
  local label="$1"
  shift
  local attempt=1
  local max_attempts=3
  while ! "$@"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "[$label] failed after $max_attempts attempts"
      return 1
    fi
    echo "[$label] attempt $attempt failed, retrying in 5s"
    sleep 5
    attempt=$((attempt + 1))
  done
}

normalize_name() {
  local text="$1"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  text="$(printf '%s' "$text" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${text:-node}"
}

renew_tls_cert_once() {
  local mode="$1"

  if /root/.acme.sh/acme.sh --renew -d "$TLS_DOMAIN_ENV" --ecc --server letsencrypt; then
    echo "[tls] renewal check succeeded during $mode"
    if /root/.acme.sh/acme.sh --install-cert -d "$TLS_DOMAIN_ENV" --ecc \
      --fullchain-file "$TLS_CERT_PATH_ENV" \
      --key-file "$TLS_KEY_PATH_ENV"; then
      return 0
    fi
    echo "[tls] install-cert failed during $mode"
    return 1
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

usque_pid() {
  cat "$USQUE_PID_FILE" 2>/dev/null || true
}

usque_running() {
  local pid
  pid="$(usque_pid)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# usque may be started by the main shell or by the monitor subshell, so the
# PID lives in a file instead of a shell variable that only one of them sees.
stop_usque() {
  local pid i
  pid="$(usque_pid)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "[usque] stopping"
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$USQUE_PID_FILE"
}

handle_signal() {
  STOP_REQUESTED="true"
  if [ -n "$WARP_MONITOR_PID" ] && kill -0 "$WARP_MONITOR_PID" 2>/dev/null; then
    kill "$WARP_MONITOR_PID" 2>/dev/null || true
    wait "$WARP_MONITOR_PID" 2>/dev/null || true
  fi
  stop_usque
  stop_singbox
  exit 0
}

# Register a MASQUE device at most once per USQUE_REGISTER_MIN_INTERVAL, so a
# Cloudflare refusal doesn't turn into a registration request every probe.
register_usque() {
  local now last wait_left out
  now="$(date +%s)"
  last="$(cat "$USQUE_REGISTER_STAMP" 2>/dev/null || printf '0')"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < USQUE_REGISTER_MIN_INTERVAL )); then
    wait_left=$(( USQUE_REGISTER_MIN_INTERVAL - (now - last) ))
    echo "[usque] registration failed recently; next attempt in ${wait_left}s"
    return 1
  fi
  printf '%s\n' "$now" > "$USQUE_REGISTER_STAMP"
  echo "[usque] registering MASQUE account"
  if out="$(usque -c "$USQUE_CONFIG" register -a -n singbox-warp 2>&1)" && [ -s "$USQUE_CONFIG" ]; then
    rm -f "$USQUE_REGISTER_STAMP"
    echo "[usque] registration succeeded"
    return 0
  fi
  rm -f "$USQUE_CONFIG"
  echo "[usque] registration failed; retrying in at most ${USQUE_REGISTER_MIN_INTERVAL}s"
  printf '%s\n' "$out" | tail -n 5 | sed 's/^/[usque]   /'
  return 1
}

start_usque() {
  if ! command -v usque >/dev/null 2>&1; then
    echo "[usque] binary is not installed"
    return 1
  fi
  if [ ! -s "$USQUE_CONFIG" ]; then
    register_usque || return 1
  fi
  stop_usque
  echo "[usque] starting SOCKS5 proxy on 127.0.0.1:${USQUE_PORT}"
  local -a args=(-c "$USQUE_CONFIG" socks -b 127.0.0.1 -p "$USQUE_PORT")
  if [ "$USQUE_HTTP2_ENV" = "true" ]; then
    args+=(--http2)
  fi
  # Send usque output to the container log (rotated by Docker) with a prefix,
  # instead of a file under /run that grows for as long as usque runs.
  usque "${args[@]}" > >(sed -u 's/^/[usque] /') 2>&1 &
  printf '%s\n' "$!" > "$USQUE_PID_FILE"
  sleep 0.5
  usque_running
}

# The MASQUE handshake can take a few seconds, so poll instead of probing once.
usque_wait_ready() {
  local deadline=$((SECONDS + USQUE_READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    usque_running || return 1
    usque_probe_once && return 0
    sleep 1
  done
  return 1
}

try_usque() {
  if start_usque && usque_wait_ready; then
    set_route_outbound "usque" || true
    return 0
  fi
  stop_usque
  return 1
}

try_wireguard() {
  if warp_probe_once; then
    stop_usque
    set_route_outbound "warp" || true
    return 0
  fi
  return 1
}

# Bring up the first working WARP egress allowed by WARP_MODE. In auto mode,
# pass the egress that just failed to try the other one first.
try_warp_egress() {
  local failed="${1:-}"
  case "$WARP_MODE_ENV" in
    usque) try_usque ;;
    wireguard) try_wireguard ;;
    auto)
      if [ "$failed" = "usque" ]; then
        try_wireguard || try_usque
      else
        try_usque || try_wireguard
      fi
      ;;
    *) return 1 ;;
  esac
}

usque_probe_once() {
  usque_running || return 1
  local probe_url
  for probe_url in "${WARP_PROBE_URLS[@]}"; do
    if curl -fsS --connect-timeout 2 --max-time 5 \
      --proxy "socks5h://127.0.0.1:${USQUE_PORT}" "$probe_url" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

start_singbox() {
  echo "[sing-box] starting"
  sing-box run -c "$SB_CONFIG" &
  SINGBOX_PID="$!"
  printf '%s\n' "$SINGBOX_PID" > "$SINGBOX_PID_FILE"
}

set_route_outbound() {
  local outbound="$1"
  local current=""
  if [ -f "$WARP_ROUTE_STATE_FILE" ]; then
    current="$(cat "$WARP_ROUTE_STATE_FILE" 2>/dev/null || true)"
  fi
  if [ "$current" = "$outbound" ]; then
    return 0
  fi

  local tmp_config
  tmp_config="$(mktemp)"
  if ! jq --arg outbound "$outbound" \
    '.route.rules = [
       {"inbound":["warp-probe"],"action":"route","outbound":"warp"},
       {"action":"route","outbound":$outbound}
     ]' \
    "$SB_CONFIG" > "$tmp_config"; then
    rm -f "$tmp_config"
    echo "[warp] failed to prepare $outbound route; keeping $current"
    return 1
  fi
  if ! jq empty "$tmp_config" >/dev/null; then
    rm -f "$tmp_config"
    echo "[warp] generated $outbound route is invalid; keeping $current"
    return 1
  fi
  mv "$tmp_config" "$SB_CONFIG"
  printf '%s\n' "$outbound" > "$WARP_ROUTE_STATE_FILE"
  echo "[warp] route switched to $outbound"
  if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
    kill -HUP "$SINGBOX_PID" 2>/dev/null || true
  fi
}

# Probe WARP through the running sing-box via a loopback-only inbound that is
# always routed to the warp endpoint. Starting a second sing-box with the same
# WireGuard key would open a competing session and could drop the live one.
warp_probe_once() {
  local i probe_url
  [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null || return 1
  for i in 1 2 3; do
    for probe_url in "${WARP_PROBE_URLS[@]}"; do
      if curl -fsS --connect-timeout 2 --max-time 4 \
        --proxy "socks5h://127.0.0.1:${WARP_PROBE_PORT}" \
        "$probe_url" >/dev/null 2>&1; then
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

route_probe() {
  case "$1" in
    usque) usque_probe_once ;;
    warp) warp_probe_once ;;
    *) return 1 ;;
  esac
}

# - A healthy egress is only abandoned after WARP_FAIL_THRESHOLD consecutive
#   failed probes (rechecked every WARP_FAIL_RECHECK_INTERVAL seconds), since
#   every route switch reloads sing-box and drops all client connections.
# - While on direct, recovery attempts back off from WARP_PROBE_INTERVAL up to
#   WARP_RETRY_MAX_INTERVAL instead of restarting usque every interval.
warp_monitor_loop() {
  local current_route last_ok="" fail_count=0 now
  local backoff="$WARP_PROBE_INTERVAL_ENV" next_retry sleep_for
  # Startup has just tried every egress, so the first retry waits one interval.
  next_retry=$(( $(date +%s) + WARP_PROBE_INTERVAL_ENV ))
  while [ "$STOP_REQUESTED" != "true" ]; do
    sleep_for="$WARP_PROBE_INTERVAL_ENV"
    current_route="$(cat "$WARP_ROUTE_STATE_FILE" 2>/dev/null || printf 'direct')"
    case "$current_route" in
      usque|warp)
        if route_probe "$current_route"; then
          if [ "$fail_count" -gt 0 ]; then
            echo "[warp] $current_route recovered after $fail_count failed probe(s)"
          elif [ "$last_ok" != "$current_route" ]; then
            echo "[warp] $current_route availability probe succeeded"
          fi
          fail_count=0
          last_ok="$current_route"
        else
          fail_count=$((fail_count + 1))
          if [ "$fail_count" -lt "$WARP_FAIL_THRESHOLD" ]; then
            echo "[warp] $current_route probe failed ($fail_count/$WARP_FAIL_THRESHOLD)"
            if [ "$WARP_FAIL_RECHECK_INTERVAL" -lt "$sleep_for" ]; then
              sleep_for="$WARP_FAIL_RECHECK_INTERVAL"
            fi
          else
            echo "[warp] $current_route failed $fail_count probes in a row; failing over"
            fail_count=0
            last_ok=""
            if try_warp_egress "$current_route"; then
              current_route="$(cat "$WARP_ROUTE_STATE_FILE" 2>/dev/null || true)"
              echo "[warp] now using $current_route"
              last_ok="$current_route"
              backoff="$WARP_PROBE_INTERVAL_ENV"
            else
              stop_usque
              set_route_outbound "direct" || true
              now="$(date +%s)"
              next_retry=$((now + backoff))
              echo "[warp] no WARP egress available; using direct, next attempt in ${backoff}s"
            fi
          fi
        fi
        ;;
      *)
        now="$(date +%s)"
        if [ "$now" -ge "$next_retry" ]; then
          if try_warp_egress; then
            current_route="$(cat "$WARP_ROUTE_STATE_FILE" 2>/dev/null || true)"
            echo "[warp] recovered; now using $current_route"
            last_ok="$current_route"
            backoff="$WARP_PROBE_INTERVAL_ENV"
          else
            stop_usque
            backoff=$((backoff * 2))
            if [ "$backoff" -gt "$WARP_RETRY_MAX_INTERVAL" ]; then
              backoff="$WARP_RETRY_MAX_INTERVAL"
            fi
            if [ "$backoff" -lt "$WARP_PROBE_INTERVAL_ENV" ]; then
              backoff="$WARP_PROBE_INTERVAL_ENV"
            fi
            next_retry=$((now + backoff))
            echo "[warp] still unavailable; next attempt in ${backoff}s"
          fi
        fi
        ;;
    esac
    sleep "$sleep_for"
  done
}

validate_required_config() {
  if [ "$AUTO_TLS_ENV" != "true" ] && [ "$AUTO_TLS_ENV" != "false" ]; then
    echo "[config] AUTO_TLS must be true or false, got: $AUTO_TLS_ENV"
    exit 1
  fi
  if [ "$ENABLE_HY2_ENV" != "true" ] && [ "$ENABLE_HY2_ENV" != "false" ]; then
    echo "[config] ENABLE_HY2 must be true or false, got: $ENABLE_HY2_ENV"
    exit 1
  fi
  if [ "$ENABLE_VLESS_ENV" != "true" ] && [ "$ENABLE_VLESS_ENV" != "false" ]; then
    echo "[config] ENABLE_VLESS must be true or false, got: $ENABLE_VLESS_ENV"
    exit 1
  fi
  if [ "$ENABLE_ANYTLS_ENV" != "true" ] && [ "$ENABLE_ANYTLS_ENV" != "false" ]; then
    echo "[config] ENABLE_ANYTLS must be true or false, got: $ENABLE_ANYTLS_ENV"
    exit 1
  fi
  if [ "$ENABLE_SS_ENV" != "true" ] && [ "$ENABLE_SS_ENV" != "false" ]; then
    echo "[config] ENABLE_SS must be true or false, got: $ENABLE_SS_ENV"
    exit 1
  fi
  if [ "$WARP_AUTORECOVER_ENV" != "true" ] && [ "$WARP_AUTORECOVER_ENV" != "false" ]; then
    echo "[config] WARP_AUTORECOVER must be true or false, got: $WARP_AUTORECOVER_ENV"
    exit 1
  fi
  case "$WARP_MODE_ENV" in
    auto|usque|wireguard|direct) ;;
    *) echo "[config] WARP_MODE must be auto, usque, wireguard, or direct, got: $WARP_MODE_ENV"; exit 1 ;;
  esac
  if [ "$USQUE_HTTP2_ENV" != "true" ] && [ "$USQUE_HTTP2_ENV" != "false" ]; then
    echo "[config] USQUE_HTTP2 must be true or false, got: $USQUE_HTTP2_ENV"
    exit 1
  fi
  validate_positive_integer "WARP_PROBE_INTERVAL" "$WARP_PROBE_INTERVAL_ENV"
  if [ "$ENABLE_HY2_ENV" != "true" ] && [ "$ENABLE_VLESS_ENV" != "true" ] &&
     [ "$ENABLE_ANYTLS_ENV" != "true" ] && [ "$ENABLE_SS_ENV" != "true" ]; then
    echo "[config] at least one inbound must be enabled"
    exit 1
  fi
  validate_positive_integer "TLS_ISSUE_RETRIES" "$TLS_ISSUE_RETRIES_ENV"
  validate_positive_integer "TLS_RENEW_INTERVAL" "$TLS_RENEW_INTERVAL_ENV"
  if [ "$ENABLE_HY2_ENV" = "true" ]; then
    validate_port "HY2_PORT" "$HY2_PORT_ENV"
  fi
  if [ "$ENABLE_VLESS_ENV" = "true" ]; then
    validate_port "VLESS_PORT" "$VLESS_PORT_ENV"
  fi
  if [ "$ENABLE_ANYTLS_ENV" = "true" ]; then
    validate_port "ANYTLS_PORT" "$ANYTLS_PORT_ENV"
  fi
  if [ "$ENABLE_SS_ENV" = "true" ]; then
    validate_port "SS_PORT" "$SS_PORT_ENV"
  fi
  validate_port "MIXED_PORT" "$MIXED_PORT_ENV"
  local internal_port
  for internal_port in "$WARP_PROBE_PORT" "$USQUE_PORT"; do
    if [ "$MIXED_PORT_ENV" = "$internal_port" ] ||
       { [ "$ENABLE_VLESS_ENV" = "true" ] && [ "$VLESS_PORT_ENV" = "$internal_port" ]; } ||
       { [ "$ENABLE_ANYTLS_ENV" = "true" ] && [ "$ANYTLS_PORT_ENV" = "$internal_port" ]; } ||
       { [ "$ENABLE_SS_ENV" = "true" ] && [ "$SS_PORT_ENV" = "$internal_port" ]; }; then
      echo "[config] port $internal_port is reserved for internal WARP probing"
      exit 1
    fi
  done

  if { [ "$ENABLE_HY2_ENV" = "true" ] && [ "$MIXED_PORT_ENV" = "$HY2_PORT_ENV" ]; } ||
     { [ "$ENABLE_VLESS_ENV" = "true" ] && [ "$MIXED_PORT_ENV" = "$VLESS_PORT_ENV" ]; } ||
     { [ "$ENABLE_ANYTLS_ENV" = "true" ] && [ "$MIXED_PORT_ENV" = "$ANYTLS_PORT_ENV" ]; } ||
     { [ "$ENABLE_SS_ENV" = "true" ] && [ "$MIXED_PORT_ENV" = "$SS_PORT_ENV" ]; } ||
     { [ "$ENABLE_HY2_ENV" = "true" ] && [ "$ENABLE_VLESS_ENV" = "true" ] && [ "$HY2_PORT_ENV" = "$VLESS_PORT_ENV" ]; } ||
     { [ "$ENABLE_HY2_ENV" = "true" ] && [ "$ENABLE_ANYTLS_ENV" = "true" ] && [ "$HY2_PORT_ENV" = "$ANYTLS_PORT_ENV" ]; } ||
     { [ "$ENABLE_HY2_ENV" = "true" ] && [ "$ENABLE_SS_ENV" = "true" ] && [ "$HY2_PORT_ENV" = "$SS_PORT_ENV" ]; } ||
     { [ "$ENABLE_VLESS_ENV" = "true" ] && [ "$ENABLE_ANYTLS_ENV" = "true" ] && [ "$VLESS_PORT_ENV" = "$ANYTLS_PORT_ENV" ]; } ||
     { [ "$ENABLE_VLESS_ENV" = "true" ] && [ "$ENABLE_SS_ENV" = "true" ] && [ "$VLESS_PORT_ENV" = "$SS_PORT_ENV" ]; } ||
     { [ "$ENABLE_ANYTLS_ENV" = "true" ] && [ "$ENABLE_SS_ENV" = "true" ] && [ "$ANYTLS_PORT_ENV" = "$SS_PORT_ENV" ]; }; then
    echo "[config] enabled inbound ports must be different"
    exit 1
  fi

  if [ "$ENABLE_VLESS_ENV" = "true" ]; then
    local effective_vless_uuid="${VLESS_UUID_ENV:-$AUTH_UUID_ENV}"
    if [ -n "$effective_vless_uuid" ] &&
       ! [[ "$effective_vless_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      echo "[config] VLESS_UUID/AUTH_UUID is not a valid UUID"
      exit 1
    fi
  fi

  if [ "$AUTO_TLS_ENV" = "true" ] && [ -z "$TLS_DOMAIN_ENV" ]; then
    echo "[config] TLS_DOMAIN is required when AUTO_TLS=true"
    exit 1
  fi

  if [ "$AUTO_TLS_ENV" != "true" ]; then
    if [ -z "$TLS_DOMAIN_ENV" ]; then
      echo "[config] TLS_DOMAIN is required for manual TLS"
      exit 1
    fi
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

trap handle_signal TERM INT HUP

mkdir -p "$WGCF_DIR" /etc/sing-box
cd "$WGCF_DIR"
validate_required_config
ensure_tls_cert

if [ ! -f "$WGCF_DIR/wgcf-account.toml" ]; then
  echo "[warp] no account found, registering new account"
  retry_command warp-register wgcf register --accept-tos
else
  echo "[warp] using existing account"
fi

PROFILE_NEEDS_REGEN="false"
if [ -n "$WARP_LICENSE_KEY_ENV" ]; then
  current_warp_license_key="$(awk -F' = ' '/^license_key/{print $2}' "$WGCF_DIR/wgcf-account.toml" | tr -d '"[:space:]' | head -n1)"
  if [ "$current_warp_license_key" != "$WARP_LICENSE_KEY_ENV" ]; then
    echo "[warp] applying WARP license key update"
    retry_command warp-license wgcf update --license-key "$WARP_LICENSE_KEY_ENV"
    PROFILE_NEEDS_REGEN="true"
  else
    echo "[warp] existing license key already matches"
  fi
fi

if [ ! -f "$WGCF_DIR/wgcf-profile.conf" ] || [ "$PROFILE_NEEDS_REGEN" = "true" ]; then
  echo "[warp] generating profile"
  retry_command warp-profile wgcf generate
fi

profile="$WGCF_DIR/wgcf-profile.conf"

WARP_PRIVATE_KEY="$(awk -F' = ' '/^PrivateKey/{print $2}' "$profile" | tr -d '[:space:]')"
WARP_ADDRESS_V4="$(awk -F' = ' '/^Address/{print $2}' "$profile" | awk -F', ' '{print $1}' | tr -d '[:space:]')"
WARP_ADDRESS_V6="$(awk -F' = ' '/^Address/{print $2}' "$profile" | awk -F', ' '{print $2}' | tr -d '[:space:]')"
WARP_PEER_PUBLIC_KEY="$(awk -F' = ' '/^PublicKey/{print $2}' "$profile" | tr -d '[:space:]' | head -n1)"
WARP_PEER_ENDPOINT="$(awk -F' = ' '/^Endpoint/{print $2}' "$profile" | tr -d '[:space:]')"
WARP_PEER_HOST="${WARP_PEER_ENDPOINT%%:*}"
WARP_PEER_PORT="${WARP_PEER_ENDPOINT##*:}"
WARP_RESERVED="$(awk -F' = ' '/^Reserved/{print $2}' "$profile" | tr -d '[:space:]' | head -n1)"

if [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_ADDRESS_V4" ] || [ -z "$WARP_PEER_PUBLIC_KEY" ] || [ -z "$WARP_PEER_HOST" ] || [ -z "$WARP_PEER_PORT" ]; then
  echo "[warp] failed to parse wgcf profile"
  exit 1
fi

cp "$SB_TEMPLATE" "$SB_CONFIG"

load_persisted_credential() {
  local key="$1"
  [ -f "$CREDENTIALS_FILE" ] || return 0
  sed -n "s/^${key}=//p" "$CREDENTIALS_FILE" | head -n1
}

save_persisted_credential() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "${CREDENTIALS_FILE}.XXXXXX")"
  if [ -f "$CREDENTIALS_FILE" ]; then
    grep -v "^${key}=" "$CREDENTIALS_FILE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CREDENTIALS_FILE"
}

# Values left empty are generated once and kept in the data volume, so a
# container restart does not rotate them and break existing clients.
if [ -z "$AUTH_UUID_ENV" ]; then
  AUTH_UUID_ENV="$(load_persisted_credential AUTH_UUID)"
  if [ -z "$AUTH_UUID_ENV" ]; then
    AUTH_UUID_ENV="$(cat /proc/sys/kernel/random/uuid)"
    save_persisted_credential AUTH_UUID "$AUTH_UUID_ENV"
    echo "[auth] generated AUTH_UUID and saved it to $CREDENTIALS_FILE"
  fi
fi
if [ -z "$HY2_PASSWORD_ENV" ]; then
  HY2_PASSWORD_ENV="$AUTH_UUID_ENV"
fi
if [ -z "$VLESS_UUID_ENV" ]; then
  VLESS_UUID_ENV="$AUTH_UUID_ENV"
fi
if [ -z "$ANYTLS_PASSWORD_ENV" ]; then
  ANYTLS_PASSWORD_ENV="$AUTH_UUID_ENV"
fi
if [ -z "$SS_PASSWORD_ENV" ]; then
  SS_PASSWORD_ENV="$(load_persisted_credential SS_PASSWORD)"
  if [ -z "$SS_PASSWORD_ENV" ]; then
    SS_PASSWORD_ENV="$(openssl rand -base64 32 | tr -d '\r\n')"
    save_persisted_credential SS_PASSWORD "$SS_PASSWORD_ENV"
    echo "[auth] generated SS_PASSWORD and saved it to $CREDENTIALS_FILE"
  fi
fi

NODE_NAME_EFFECTIVE="$NODE_NAME_ENV"
if [ -z "$NODE_NAME_EFFECTIVE" ]; then
  NODE_NAME_EFFECTIVE="$TLS_DOMAIN_ENV"
fi
NODE_NAME_EFFECTIVE="$(normalize_name "$NODE_NAME_EFFECTIVE")"
HY2_TAG_ENV="hy2-${NODE_NAME_EFFECTIVE}"
VLESS_TAG_ENV="vless-${NODE_NAME_EFFECTIVE}"

sed -i \
  -e "s|__HY2_PORT__|$HY2_PORT_ENV|g" \
  -e "s|__VLESS_PORT__|$VLESS_PORT_ENV|g" \
  -e "s|__ANYTLS_PORT__|$ANYTLS_PORT_ENV|g" \
  -e "s|__SS_PORT__|$SS_PORT_ENV|g" \
  -e "s|__HY2_TAG__|$HY2_TAG_ENV|g" \
  -e "s|__VLESS_TAG__|$VLESS_TAG_ENV|g" \
  -e "s|__WARP_PEER_PORT__|$WARP_PEER_PORT|g" \
  -e "s|__MIXED_PORT__|$MIXED_PORT_ENV|g" \
  "$SB_CONFIG"

tmp_config="$(mktemp)"
jq \
  --arg hy2Password "$HY2_PASSWORD_ENV" \
  --arg vlessUuid "$VLESS_UUID_ENV" \
  --arg anytlsPassword "$ANYTLS_PASSWORD_ENV" \
  --arg ssPassword "$SS_PASSWORD_ENV" \
  --arg tlsDomain "$TLS_DOMAIN_ENV" \
  --arg tlsCertPath "$TLS_CERT_PATH_ENV" \
  --arg tlsKeyPath "$TLS_KEY_PATH_ENV" \
  --arg warpPrivateKey "$WARP_PRIVATE_KEY" \
  --arg warpAddressV4 "$WARP_ADDRESS_V4" \
  --arg warpAddressV6 "$WARP_ADDRESS_V6" \
  --arg warpPeerPublicKey "$WARP_PEER_PUBLIC_KEY" \
  --arg warpPeerHost "$WARP_PEER_HOST" \
  --arg warpReserved "$WARP_RESERVED" \
  --arg enableHy2 "$ENABLE_HY2_ENV" \
  --arg enableVless "$ENABLE_VLESS_ENV" \
  --arg enableAnytls "$ENABLE_ANYTLS_ENV" \
  --arg enableSs "$ENABLE_SS_ENV" \
  --arg hy2Tag "$HY2_TAG_ENV" \
  --arg vlessTag "$VLESS_TAG_ENV" \
  '
  (.inbounds[] | select(.type=="hysteria2") | .users[0].password) = $hy2Password |
  (.inbounds[] | select(.type=="vless") | .users[0].uuid) = $vlessUuid |
  (.inbounds[] | select(.type=="anytls") | .users[0].password) = $anytlsPassword |
  (.inbounds[] | select(.type=="shadowsocks") | .password) = $ssPassword |
  (.inbounds[] | select(.type=="hysteria2") | .tag) = $hy2Tag |
  (.inbounds[] | select(.type=="vless") | .tag) = $vlessTag |
  (.inbounds[] | select(.type=="hysteria2" or .type=="vless" or .type=="anytls") | .tls.server_name) = $tlsDomain |
  (.inbounds[] | select(.type=="hysteria2" or .type=="vless" or .type=="anytls") | .tls.certificate_path) = $tlsCertPath |
  (.inbounds[] | select(.type=="hysteria2" or .type=="vless" or .type=="anytls") | .tls.key_path) = $tlsKeyPath |
  .inbounds |= map(select(
    (.type=="hysteria2" and $enableHy2=="true") or
    (.type=="vless" and $enableVless=="true") or
    (.type=="anytls" and $enableAnytls=="true") or
    (.type=="shadowsocks" and $enableSs=="true") or
    (.type=="mixed") or
    (.type!="hysteria2" and .type!="vless" and .type!="anytls" and .type!="shadowsocks" and .type!="mixed")
  )) |
  (.endpoints[] | select(.tag=="warp") | .address) = [$warpAddressV4, $warpAddressV6] |
  (.endpoints[] | select(.tag=="warp") | .private_key) = $warpPrivateKey |
  (.endpoints[] | select(.tag=="warp") | .peers[0].address) = $warpPeerHost |
  (.endpoints[] | select(.tag=="warp") | .peers[0].public_key) = $warpPeerPublicKey |
  if $warpReserved != "" then
    (.endpoints[] | select(.tag=="warp") | .peers[0].reserved) =
      ($warpReserved | split(",") | map(tonumber))
  else
    .
  end
  ' \
  "$SB_CONFIG" > "$tmp_config"
mv "$tmp_config" "$SB_CONFIG"

jq empty "$SB_CONFIG" >/dev/null

cp "$SB_CONFIG" "${SB_CONFIG}.pre-warp-fallback" 2>/dev/null || true
set_route_outbound "direct"

uri_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

print_node_links() {
  local cfg="$SB_CONFIG" host="$TLS_DOMAIN_ENV" tag port link userinfo method
  if [ "$ENABLE_HY2_ENV" = "true" ]; then
    tag="$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tag' "$cfg" | head -n1)"
    link="hy2://$(uri_encode "$HY2_PASSWORD_ENV")@${host}:${HY2_PORT_ENV}?sni=${host}"
    if [ "$HY2_PORT_HOPPING_ENV" = "true" ] && [ -n "$HY2_HOP_PORTS_ENV" ]; then
      link="${link}&mport=${HY2_HOP_PORTS_ENV}"
    fi
    echo "[node] ${link}&insecure=0#$(uri_encode "$tag")"
  fi
  if [ "$ENABLE_VLESS_ENV" = "true" ]; then
    tag="$(jq -r '.inbounds[] | select(.type=="vless") | .tag' "$cfg" | head -n1)"
    echo "[node] vless://${VLESS_UUID_ENV}@${host}:${VLESS_PORT_ENV}?encryption=none&security=tls&sni=${host}&type=tcp&flow=xtls-rprx-vision#$(uri_encode "$tag")"
  fi
  if [ "$ENABLE_ANYTLS_ENV" = "true" ]; then
    tag="$(jq -r '.inbounds[] | select(.type=="anytls") | .tag' "$cfg" | head -n1)"
    echo "[node] anytls://$(uri_encode "$ANYTLS_PASSWORD_ENV")@${host}:${ANYTLS_PORT_ENV}/?sni=${host}#$(uri_encode "$tag")"
  fi
  if [ "$ENABLE_SS_ENV" = "true" ]; then
    tag="$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .tag' "$cfg" | head -n1)"
    method="$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method' "$cfg" | head -n1)"
    userinfo="$(printf '%s:%s' "$method" "$SS_PASSWORD_ENV" | base64 -w0)"
    echo "[node] ss://${userinfo}@${host}:${SS_PORT_ENV}#$(uri_encode "$tag")"
  fi
}

print_node_links

start_singbox

case "$WARP_MODE_ENV" in
  direct)
    echo "[warp] mode=direct"
    ;;
  *)
    if try_warp_egress; then
      echo "[warp] using $(cat "$WARP_ROUTE_STATE_FILE")"
    else
      stop_usque
      echo "[warp] no WARP egress available (mode=$WARP_MODE_ENV); using direct"
    fi
    ;;
esac

# direct mode has nothing to recover, so the monitor would only spin.
if [ "$WARP_AUTORECOVER_ENV" = "true" ] && [ "$WARP_MODE_ENV" != "direct" ]; then
  warp_monitor_loop &
  WARP_MONITOR_PID="$!"
fi

elapsed_seconds=0
while true; do
  if [ "$STOP_REQUESTED" = "true" ]; then
    exit 0
  fi

  if ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
    echo "[sing-box] process exited"
    wait "$SINGBOX_PID" || true
    exit 1
  fi

  # Background sleep + wait so a stop signal is handled at once instead of
  # after the sleep finishes.
  sleep "$PROCESS_CHECK_INTERVAL_SECONDS" &
  wait "$!" || true
  elapsed_seconds=$((elapsed_seconds + PROCESS_CHECK_INTERVAL_SECONDS))
  if [ "$elapsed_seconds" -ge "$TLS_RENEW_INTERVAL_ENV" ]; then
    elapsed_seconds=0
    renew_tls_cert_if_needed
  fi
done
