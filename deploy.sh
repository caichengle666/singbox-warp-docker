#!/usr/bin/env bash
set -euo pipefail

APP_DIR_DEFAULT="/opt/singbox-warp"
IMAGE_DEFAULT="ghcr.io/caichengle666/singbox-warp-docker:latest"
COMPOSE_FILE_NAME="docker-compose.yml"
ENV_FILE_NAME=".env"
STATE_DIR_NAME=".deploy-state"

APP_DIR="${APP_DIR:-$APP_DIR_DEFAULT}"
IMAGE="${IMAGE:-$IMAGE_DEFAULT}"
HY2_PORT="${HY2_PORT:-32443}"
VLESS_PORT="${VLESS_PORT:-38443}"
ENABLE_HY2="${ENABLE_HY2:-true}"
ENABLE_VLESS="${ENABLE_VLESS:-true}"
AUTO_TLS="${AUTO_TLS:-false}"
AUTO_DOMAIN="${AUTO_DOMAIN:-true}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
TLS_DOMAIN="${TLS_DOMAIN:-}"
AUTH_UUID="${AUTH_UUID:-}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
VLESS_UUID="${VLESS_UUID:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}"
TLS_KEY_PATH="${TLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}"
TLS_ISSUE_RETRIES="${TLS_ISSUE_RETRIES:-3}"
TLS_RENEW_INTERVAL="${TLS_RENEW_INTERVAL:-43200}"
WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
CF_Token="${CF_Token:-}"
CF_Account_ID="${CF_Account_ID:-}"
CF_Zone_ID="${CF_Zone_ID:-}"

COMPOSE_FILE="$APP_DIR/$COMPOSE_FILE_NAME"
ENV_FILE="$APP_DIR/$ENV_FILE_NAME"
STATE_DIR="$APP_DIR/$STATE_DIR_NAME"
ROLLBACK_FILE="$STATE_DIR/last_image.txt"

log() { printf '[deploy] %s\n' "$*"; }
err() { printf '[deploy][error] %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "missing command: $1"
    exit 1
  }
}

usage() {
  cat <<'EOF'
Usage:
  deploy.sh                 # same as bootstrap
  deploy.sh bootstrap [--yes]
  deploy.sh init
  deploy.sh deploy
  deploy.sh status
  deploy.sh rollback [IMAGE_OR_DIGEST]

Environment:
  APP_DIR         Deploy directory (default: /opt/singbox-warp)
  IMAGE           Runtime image (default: ghcr.io/caichengle666/singbox-warp-docker:latest)

  AUTO_TLS        true/false (required)
  AUTO_DOMAIN     true/false (default: true, with AUTO_TLS=true)
  BASE_DOMAIN     base domain for auto subdomain (example: 1100.ccwu.cc)
  TLS_DOMAIN      Recommended for node links, required when AUTO_TLS=true
  CF_Token        Required when AUTO_TLS=true

  HY2_PORT        Default 32443
  VLESS_PORT      Default 38443
  AUTH_UUID       Optional fixed auth value
  HY2_PASSWORD    Optional override
  VLESS_UUID      Optional override

  Manual TLS mode requires:
    APP_DIR/certs/fullchain.pem
    APP_DIR/certs/privkey.pem
EOF
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

run_root() {
  if is_root; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    err "root privileges are required for: $*"
    exit 1
  fi
}

validate_bool() {
  case "$1" in
    true|false) ;;
    *)
      err "AUTO_TLS must be true or false, got: $1"
      exit 1
      ;;
  esac
}

ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  read -r value || true
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  printf '%s' "$value"
}

ask_choice() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    printf "%s [%s]: " "$prompt" "$default" >&2
    read -r value || true
    value="${value:-$default}"
    case "$value" in
      true|false|yes|no|y|n)
        printf '%s' "$value"
        return 0
        ;;
      *)
        err "invalid choice: $value (expected true/false/yes/no)"
        ;;
    esac
  done
}

normalize_bool() {
  case "$1" in
    true|yes) printf 'true' ;;
    y) printf 'true' ;;
    false|no) printf 'false' ;;
    n) printf 'false' ;;
    *)
      err "invalid boolean value: $1"
      exit 1
      ;;
  esac
}

normalize_name() {
  local text="$1"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  text="$(printf '%s' "$text" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${text:-node}"
}

detect_cpu_flavor() {
  local info
  info="$(tr '[:upper:]' '[:lower:]' </proc/cpuinfo 2>/dev/null || true)"
  if printf '%s' "$info" | grep -Eq 'amd|epyc|ryzen'; then
    printf 'amd'
  elif printf '%s' "$info" | grep -Eq 'intel|xeon'; then
    printf 'intel'
  elif printf '%s' "$info" | grep -Eq 'arm|aarch64|graviton'; then
    printf 'arm'
  else
    printf 'cpu'
  fi
}

detect_mem_label() {
  local kb gb
  kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ -z "$kb" || "$kb" -le 0 ]]; then
    printf '1g'
    return 0
  fi
  gb=$(( (kb + 1024*1024 - 1) / (1024*1024) ))
  if [[ "$gb" -lt 1 ]]; then
    gb=1
  fi
  printf '%sg' "$gb"
}

get_public_ip() {
  local ip
  ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsSL https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  fi
  printf '%s' "$ip"
}

detect_country_code() {
  local ip="$1"
  local code=""
  code="$(curl -fsSL "https://ipapi.co/${ip}/country/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' || true)"
  if [[ ! "$code" =~ ^[a-z]{2}$ ]]; then
    code="$(curl -fsSL "https://ipwho.is/${ip}" 2>/dev/null | jq -r '.country_code // empty' | tr '[:upper:]' '[:lower:]' || true)"
  fi
  if [[ ! "$code" =~ ^[a-z]{2}$ ]]; then
    code="xx"
  fi
  printf '%s' "$code"
}

resolve_zone_id() {
  local zone_name="$1"
  local token="$2"
  local zid
  zid="$(curl -fsSL -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=$zone_name&status=active" \
    | jq -r '.result[0].id // empty')"
  printf '%s' "$zid"
}

upsert_cloudflare_a_record() {
  local fqdn="$1"
  local zone_id="$2"
  local token="$3"
  local ip="$4"
  local proxied="${5:-false}"
  local record_id
  record_id="$(curl -fsSL -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$fqdn" \
    | jq -r '.result[0].id // empty')"

  if [[ -n "$record_id" ]]; then
    curl -fsSL -X PUT -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":$proxied}" \
      | jq -e '.success == true' >/dev/null
    log "updated Cloudflare A record: $fqdn -> $ip"
  else
    curl -fsSL -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":$proxied}" \
      | jq -e '.success == true' >/dev/null
    log "created Cloudflare A record: $fqdn -> $ip"
  fi
}

prepare_auto_domain() {
  if [[ "$AUTO_TLS" != "true" || "$AUTO_DOMAIN" != "true" ]]; then
    return 0
  fi
  [[ -n "$BASE_DOMAIN" ]] || { err "BASE_DOMAIN is required when AUTO_DOMAIN=true"; exit 1; }
  [[ -n "$CF_Token" ]] || { err "CF_Token is required when AUTO_DOMAIN=true"; exit 1; }
  need_cmd curl
  need_cmd jq

  local ip cpu mem country zone_id
  ip="$(get_public_ip)"
  [[ -n "$ip" ]] || { err "failed to detect public IPv4"; exit 1; }
  cpu="$(detect_cpu_flavor)"
  mem="$(detect_mem_label)"
  country="$(detect_country_code "$ip")"
  TLS_DOMAIN="${cpu}${mem}-${country}.${BASE_DOMAIN}"

  if [[ -n "$CF_Zone_ID" ]]; then
    zone_id="$CF_Zone_ID"
  else
    zone_id="$(resolve_zone_id "$BASE_DOMAIN" "$CF_Token")"
  fi
  [[ -n "$zone_id" ]] || { err "failed to resolve Cloudflare zone id for $BASE_DOMAIN"; exit 1; }
  CF_Zone_ID="$zone_id"
  upsert_cloudflare_a_record "$TLS_DOMAIN" "$CF_Zone_ID" "$CF_Token" "$ip" "false"
  log "auto domain selected: $TLS_DOMAIN"
}

validate_true_false() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *)
      err "$name must be true or false, got: $value"
      exit 1
      ;;
  esac
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker already installed: $(docker --version)"
    return 0
  fi

  log "docker not found, installing docker engine"
  if [[ ! -f /etc/os-release ]]; then
    err "unsupported system: /etc/os-release not found"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  local distro="${ID:-}"
  local codename="${VERSION_CODENAME:-}"
  if [[ "$distro" != "ubuntu" && "$distro" != "debian" ]]; then
    err "unsupported distro for auto-install: ${distro:-unknown} (supported: ubuntu/debian)"
    exit 1
  fi
  if [[ -z "$codename" ]]; then
    err "failed to detect distro codename for docker apt repo"
    exit 1
  fi

  run_root apt-get update -y
  run_root apt-get install -y ca-certificates curl gnupg
  run_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" | run_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  run_root chmod a+r /etc/apt/keyrings/docker.gpg
  printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n" \
    "$(dpkg --print-architecture)" "$distro" "$codename" | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  run_root apt-get update -y
  run_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_root systemctl enable docker >/dev/null 2>&1 || true
  run_root systemctl restart docker
  log "docker installation completed"
}

collect_bootstrap_inputs() {
  local assume_yes="${1:-false}"
  if [[ "$assume_yes" == "true" ]]; then
    AUTO_TLS="$(normalize_bool "${AUTO_TLS:-false}")"
    AUTO_DOMAIN="$(normalize_bool "${AUTO_DOMAIN:-true}")"
    return 0
  fi

  APP_DIR="$(ask_input "Deploy directory" "$APP_DIR")"
  IMAGE="$(ask_input "Image" "$IMAGE")"
  HY2_PORT="$(ask_input "HY2 port" "$HY2_PORT")"
  VLESS_PORT="$(ask_input "VLESS port" "$VLESS_PORT")"
  ENABLE_HY2="$(normalize_bool "$(ask_choice "Enable HY2 (y/n or true/false)" "${ENABLE_HY2}")")"
  ENABLE_VLESS="$(normalize_bool "$(ask_choice "Enable VLESS (y/n or true/false)" "${ENABLE_VLESS}")")"
  AUTO_TLS="$(normalize_bool "$(ask_choice "Enable AUTO_TLS (true/false)" "$AUTO_TLS")")"
  AUTO_DOMAIN="$(normalize_bool "$(ask_choice "Auto-generate subdomain (y/n)" "$AUTO_DOMAIN")")"
  if [[ "$AUTO_DOMAIN" == "true" ]]; then
    BASE_DOMAIN="$(ask_input "Base domain (example: 1100.ccwu.cc)" "$BASE_DOMAIN")"
  else
    TLS_DOMAIN="$(ask_input "TLS domain (required when AUTO_TLS=true)" "$TLS_DOMAIN")"
  fi
  AUTH_UUID="$(ask_input "AUTH_UUID (optional, blank=auto-generate)" "$AUTH_UUID")"
  HY2_PASSWORD="$(ask_input "HY2_PASSWORD (optional)" "$HY2_PASSWORD")"
  VLESS_UUID="$(ask_input "VLESS_UUID (optional)" "$VLESS_UUID")"
  WARP_LICENSE_KEY="$(ask_input "WARP_LICENSE_KEY (optional)" "$WARP_LICENSE_KEY")"
  TLS_ISSUE_RETRIES="$(ask_input "TLS issue retries" "$TLS_ISSUE_RETRIES")"
  TLS_RENEW_INTERVAL="$(ask_input "TLS renew interval seconds" "$TLS_RENEW_INTERVAL")"

  if [[ "$AUTO_TLS" == "true" ]]; then
    ACME_EMAIL="$(ask_input "ACME_EMAIL (recommended)" "$ACME_EMAIL")"
    CF_Token="$(ask_input "CF_Token (required when AUTO_TLS=true)" "$CF_Token")"
    CF_Account_ID="$(ask_input "CF_Account_ID (optional)" "$CF_Account_ID")"
    CF_Zone_ID="$(ask_input "CF_Zone_ID (optional)" "$CF_Zone_ID")"
  fi
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    err "$name must be a positive integer, got: $value"
    exit 1
  }
}

validate_config() {
  validate_true_false "ENABLE_HY2" "$ENABLE_HY2"
  validate_true_false "ENABLE_VLESS" "$ENABLE_VLESS"
  validate_true_false "AUTO_DOMAIN" "$AUTO_DOMAIN"
  validate_bool "$AUTO_TLS"
  if [[ "$ENABLE_HY2" == "true" ]]; then
    validate_positive_int "HY2_PORT" "$HY2_PORT"
  fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    validate_positive_int "VLESS_PORT" "$VLESS_PORT"
  fi
  validate_positive_int "TLS_ISSUE_RETRIES" "$TLS_ISSUE_RETRIES"
  validate_positive_int "TLS_RENEW_INTERVAL" "$TLS_RENEW_INTERVAL"
  if [[ "$ENABLE_HY2" != "true" && "$ENABLE_VLESS" != "true" ]]; then
    err "at least one protocol must be enabled (ENABLE_HY2/ENABLE_VLESS)"
    exit 1
  fi

  if [[ "$AUTO_TLS" == "true" ]]; then
    if [[ "$AUTO_DOMAIN" != "true" ]]; then
      [[ -n "$TLS_DOMAIN" ]] || { err "TLS_DOMAIN is required when AUTO_TLS=true and AUTO_DOMAIN=false"; exit 1; }
    fi
    [[ -n "$CF_Token" ]] || { err "CF_Token is required when AUTO_TLS=true"; exit 1; }
  else
    [[ -s "$APP_DIR/certs/fullchain.pem" ]] || {
      err "manual TLS mode requires $APP_DIR/certs/fullchain.pem"
      exit 1
    }
    [[ -s "$APP_DIR/certs/privkey.pem" ]] || {
      err "manual TLS mode requires $APP_DIR/certs/privkey.pem"
      exit 1
    }
  fi
}

write_compose() {
  local ports_block=""
  if [[ "$ENABLE_HY2" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${HY2_PORT:-32443}:\${HY2_PORT:-32443}/tcp\"
      - \"\${HY2_PORT:-32443}:\${HY2_PORT:-32443}/udp\""
  fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${VLESS_PORT:-38443}:\${VLESS_PORT:-38443}/tcp\""
  fi

  cat >"$COMPOSE_FILE" <<EOF
services:
  singbox-warp:
    image: ${IMAGE}
    container_name: singbox-warp
    restart: unless-stopped
    ports:
${ports_block}
    volumes:
      - ./data:/var/lib/wgcf
      - ./certs:/etc/sing-box/certs
      - ./acme:/var/lib/acme
    cap_add:
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    mem_limit: 512m
    pids_limit: 256
    healthcheck:
      test: ["CMD-SHELL", "test -s /run/sing-box.pid && kill -0 \"\$(cat /run/sing-box.pid)\""]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    environment:
      - HY2_PORT=\${HY2_PORT:-32443}
      - VLESS_PORT=\${VLESS_PORT:-38443}
      - ENABLE_HY2=\${ENABLE_HY2:-true}
      - ENABLE_VLESS=\${ENABLE_VLESS:-true}
      - AUTH_UUID=\${AUTH_UUID:-}
      - HY2_PASSWORD=\${HY2_PASSWORD:-}
      - VLESS_UUID=\${VLESS_UUID:-}
      - AUTO_TLS=\${AUTO_TLS:-false}
      - TLS_DOMAIN=\${TLS_DOMAIN:-}
      - TLS_CERT_PATH=\${TLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}
      - TLS_KEY_PATH=\${TLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}
      - ACME_EMAIL=\${ACME_EMAIL:-}
      - TLS_ISSUE_RETRIES=\${TLS_ISSUE_RETRIES:-3}
      - TLS_RENEW_INTERVAL=\${TLS_RENEW_INTERVAL:-43200}
      - WARP_LICENSE_KEY=\${WARP_LICENSE_KEY:-}
      - CF_Token=\${CF_Token:-}
      - CF_Account_ID=\${CF_Account_ID:-}
      - CF_Zone_ID=\${CF_Zone_ID:-}
EOF
}

write_env() {
  cat >"$ENV_FILE" <<EOF
HY2_PORT=$HY2_PORT
VLESS_PORT=$VLESS_PORT
ENABLE_HY2=$ENABLE_HY2
ENABLE_VLESS=$ENABLE_VLESS
AUTO_DOMAIN=$AUTO_DOMAIN
BASE_DOMAIN=$BASE_DOMAIN
AUTH_UUID=$AUTH_UUID
HY2_PASSWORD=$HY2_PASSWORD
VLESS_UUID=$VLESS_UUID
AUTO_TLS=$AUTO_TLS
TLS_DOMAIN=$TLS_DOMAIN
TLS_CERT_PATH=$TLS_CERT_PATH
TLS_KEY_PATH=$TLS_KEY_PATH
ACME_EMAIL=$ACME_EMAIL
TLS_ISSUE_RETRIES=$TLS_ISSUE_RETRIES
TLS_RENEW_INTERVAL=$TLS_RENEW_INTERVAL
WARP_LICENSE_KEY=$WARP_LICENSE_KEY
CF_Token=$CF_Token
CF_Account_ID=$CF_Account_ID
CF_Zone_ID=$CF_Zone_ID
EOF
  log "created .env: $ENV_FILE"
}

write_env_if_missing() {
  if [[ -f "$ENV_FILE" ]]; then
    log ".env exists, keep current file: $ENV_FILE"
    return 0
  fi
  write_env
}

record_current_image_for_rollback() {
  mkdir -p "$STATE_DIR"
  if docker inspect singbox-warp --format '{{.Config.Image}}' >/dev/null 2>&1; then
    docker inspect singbox-warp --format '{{.Config.Image}}' >"$ROLLBACK_FILE" || true
  elif [[ -f "$COMPOSE_FILE" ]]; then
    grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n1 | sed -E 's/^\s*image:\s*//' >"$ROLLBACK_FILE" || true
  fi
}

wait_healthy() {
  local i
  for i in $(seq 1 30); do
    local s
    s="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' singbox-warp 2>/dev/null || true)"
    log "health check $i/30: $s"
    if [[ "$s" == "healthy" ]]; then
      return 0
    fi
    sleep 2
  done
  err "container is not healthy"
  docker ps --format '{{.Names}} {{.Status}} {{.Image}}' | grep '^singbox-warp ' || true
  docker logs --tail 80 singbox-warp || true
  exit 1
}

cmd_init() {
  need_cmd docker
  mkdir -p "$APP_DIR"/{data,certs,acme}
  write_compose
  write_env
  log "init done: $APP_DIR"
  log "next: edit $ENV_FILE, then run: $0 deploy"
}

cmd_deploy() {
  need_cmd docker
  [[ -f "$COMPOSE_FILE" ]] || { err "missing compose file: $COMPOSE_FILE"; exit 1; }
  [[ -f "$ENV_FILE" ]] || { err "missing env file: $ENV_FILE"; exit 1; }

  # shellcheck disable=SC1090
  source "$ENV_FILE"
  validate_config
  prepare_auto_domain
  write_env
  record_current_image_for_rollback

  (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  )
  wait_healthy
  log "deploy done"
}

cmd_status() {
  need_cmd docker
  docker ps --format '{{.Names}} {{.Status}} {{.Image}}' | grep '^singbox-warp ' || {
    err "singbox-warp container not running"
    exit 1
  }
  docker inspect singbox-warp --format 'ConfigImage={{.Config.Image}}'
  docker inspect singbox-warp --format 'ImageID={{.Image}}'
  docker inspect singbox-warp --format 'Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
}

cmd_rollback() {
  need_cmd docker
  local rollback_image="${1:-}"
  if [[ -z "$rollback_image" ]]; then
    [[ -f "$ROLLBACK_FILE" ]] || {
      err "no rollback image found. pass image manually: $0 rollback <image|digest>"
      exit 1
    }
    rollback_image="$(cat "$ROLLBACK_FILE")"
  fi

  [[ -f "$COMPOSE_FILE" ]] || { err "missing compose file: $COMPOSE_FILE"; exit 1; }
  sed -i -E "s#^(\s*image:\s*).+#\1${rollback_image}#" "$COMPOSE_FILE"
  (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  )
  wait_healthy
  log "rollback done: $rollback_image"
}

cmd_bootstrap() {
  local assume_yes="false"
  if [[ "${1:-}" == "--yes" ]]; then
    assume_yes="true"
  fi
  if [[ "${1:-}" != "" && "${1:-}" != "--yes" ]]; then
    err "unknown bootstrap option: ${1:-}"
    exit 1
  fi

  collect_bootstrap_inputs "$assume_yes"
  validate_config
  prepare_auto_domain
  ensure_docker

  mkdir -p "$APP_DIR"/{data,certs,acme}
  write_compose
  write_env

  (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  )
  wait_healthy
  log "bootstrap completed: $APP_DIR"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    cmd_bootstrap
    return 0
  fi
  case "$cmd" in
    bootstrap) shift; cmd_bootstrap "${1:-}" ;;
    init) cmd_init ;;
    deploy) cmd_deploy ;;
    status) cmd_status ;;
    rollback) cmd_rollback "${2:-}" ;;
    -h|--help|help) usage ;;
    *)
      err "unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
