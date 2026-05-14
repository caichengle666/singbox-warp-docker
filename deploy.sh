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
AUTO_TLS="${AUTO_TLS:-false}"
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
  deploy.sh init
  deploy.sh deploy
  deploy.sh status
  deploy.sh rollback [IMAGE_OR_DIGEST]

Environment:
  APP_DIR         Deploy directory (default: /opt/singbox-warp)
  IMAGE           Runtime image (default: ghcr.io/caichengle666/singbox-warp-docker:latest)

  AUTO_TLS        true/false (required)
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

validate_bool() {
  case "$1" in
    true|false) ;;
    *)
      err "AUTO_TLS must be true or false, got: $1"
      exit 1
      ;;
  esac
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
  validate_bool "$AUTO_TLS"
  validate_positive_int "HY2_PORT" "$HY2_PORT"
  validate_positive_int "VLESS_PORT" "$VLESS_PORT"
  validate_positive_int "TLS_ISSUE_RETRIES" "$TLS_ISSUE_RETRIES"
  validate_positive_int "TLS_RENEW_INTERVAL" "$TLS_RENEW_INTERVAL"

  if [[ "$AUTO_TLS" == "true" ]]; then
    [[ -n "$TLS_DOMAIN" ]] || { err "TLS_DOMAIN is required when AUTO_TLS=true"; exit 1; }
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
  cat >"$COMPOSE_FILE" <<EOF
services:
  singbox-warp:
    image: ${IMAGE}
    container_name: singbox-warp
    restart: unless-stopped
    ports:
      - "\${HY2_PORT:-32443}:\${HY2_PORT:-32443}/tcp"
      - "\${HY2_PORT:-32443}:\${HY2_PORT:-32443}/udp"
      - "\${VLESS_PORT:-38443}:\${VLESS_PORT:-38443}/tcp"
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

write_env_if_missing() {
  if [[ -f "$ENV_FILE" ]]; then
    log ".env exists, keep current file: $ENV_FILE"
    return 0
  fi

  cat >"$ENV_FILE" <<EOF
HY2_PORT=$HY2_PORT
VLESS_PORT=$VLESS_PORT
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
  write_env_if_missing
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

main() {
  local cmd="${1:-}"
  case "$cmd" in
    init) cmd_init ;;
    deploy) cmd_deploy ;;
    status) cmd_status ;;
    rollback) cmd_rollback "${2:-}" ;;
    -h|--help|help|"") usage ;;
    *)
      err "unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
