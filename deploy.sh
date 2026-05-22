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
NODE_NAME="${NODE_NAME:-}"
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

refresh_paths() {
  COMPOSE_FILE="$APP_DIR/$COMPOSE_FILE_NAME"
  ENV_FILE="$APP_DIR/$ENV_FILE_NAME"
  STATE_DIR="$APP_DIR/$STATE_DIR_NAME"
  ROLLBACK_FILE="$STATE_DIR/last_image.txt"
}

log() { printf '[deploy] %s\n' "$*"; }
err() { printf '[deploy][error] %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令: $1"
    exit 1
  }
}

self_install_swd() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    return 0
  fi
  local target="/usr/local/bin/swd"
  if [[ ! -w "/usr/local/bin" ]]; then
    return 0
  fi
  cp -f "$0" "$target" 2>/dev/null || return 0
  chmod +x "$target" 2>/dev/null || true
}

usage() {
  cat <<'EOF'
Usage:
  deploy.sh

Environment:
  APP_DIR         部署目录 (default: /opt/singbox-warp)
  IMAGE           Runtime image (default: ghcr.io/caichengle666/singbox-warp-docker:latest)

  AUTO_TLS        true/false (required)
  AUTO_DOMAIN     true/false (default: true, with AUTO_TLS=true)
  BASE_DOMAIN     自动子域名的主域名 (example: 1100.ccwu.cc)
  TLS_DOMAIN      节点链接使用的域名，AUTO_TLS=true 时必填
  NODE_NAME       节点名称前缀
  CF_Token        AUTO_TLS=true 时必填

  HY2_PORT        默认 32443
  VLESS_PORT      默认 38443
  AUTH_UUID       可选，固定认证值
  HY2_PASSWORD    可选，覆盖 HY2 密码
  VLESS_UUID      可选，覆盖 VLESS UUID

  手动证书模式需要：
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
    err "执行以下命令需要 root 权限: $*"
    exit 1
  fi
}

validate_bool() {
  case "$1" in
    true|false) ;;
    *)
      err "AUTO_TLS 必须是 true 或 false，当前值: $1"
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
  if [[ "${FORCE_STDIN:-0}" == "1" ]]; then
    if ! read -r value; then
      err "未能从 stdin 读取交互输入"
      exit 1
    fi
  elif [[ -r /dev/tty ]]; then
    if ! read -r value < /dev/tty; then
      err "未能从终端读取交互输入"
      exit 1
    fi
  else
    if ! read -r value; then
      err "未检测到交互终端；请使用: curl ... -o deploy.sh && bash deploy.sh"
      exit 1
    fi
  fi
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
    if [[ "${FORCE_STDIN:-0}" == "1" ]]; then
      if ! read -r value; then
        err "未能从 stdin 读取交互输入"
        exit 1
      fi
    elif [[ -r /dev/tty ]]; then
      if ! read -r value < /dev/tty; then
        err "未能从终端读取交互输入"
        exit 1
      fi
    else
      if ! read -r value; then
        err "未检测到交互终端；请使用: curl ... -o deploy.sh && bash deploy.sh"
        exit 1
      fi
    fi
    value="${value:-$default}"
    case "$value" in
      true|false|yes|no|y|n)
        printf '%s' "$value"
        return 0
        ;;
      *)
        err "输入无效: $value (请输入 true/false/yes/no)"
        ;;
    esac
  done
}

ask_menu_choice() {
  local value=""
  while true; do
    printf "\n请选择操作:\n" >&2
    printf "  1) 部署 / 更新\n" >&2
    printf "  2) 查看节点链接\n" >&2
    printf "  3) 查看运行状态\n" >&2
    printf "  4) 退出\n" >&2
    printf "请输入 [1-4]: " >&2
    if [[ "${FORCE_STDIN:-0}" == "1" ]]; then
      if ! read -r value; then
        err "未能从 stdin 读取交互输入"
        exit 1
      fi
    elif [[ -r /dev/tty ]]; then
      if ! read -r value < /dev/tty; then
        err "未能从终端读取交互输入"
        exit 1
      fi
    else
      if ! read -r value; then
        err "未检测到交互终端；请使用: curl ... -o deploy.sh && bash deploy.sh"
        exit 1
      fi
    fi
    if [[ -z "$value" ]]; then
      err "未输入内容，请输入 1-4"
      continue
    fi
    case "$value" in
      1|2|3|4)
        printf '%s' "$value"
        return 0
        ;;
      *)
        err "菜单选择无效: ${value:-empty}"
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

resolve_node_name() {
  local source_name="${NODE_NAME:-}"
  if [[ -z "$source_name" ]]; then
    # 自动生成：amd1g-{IP末段}-{城市简称}
    local ip cpu mem city ip_suffix
    ip="$(get_public_ip 2>/dev/null || echo "")"
    if [[ -n "$ip" ]]; then
      cpu="$(detect_cpu_flavor)"
      mem="$(detect_mem_label)"
      city="$(detect_city_code "$ip" 2>/dev/null || echo "x")"
      ip_suffix="${ip##*.}"
      source_name="${cpu}${mem}-${ip_suffix}-${city}"
    else
      source_name="${TLS_DOMAIN:-node}"
    fi
  fi
  normalize_name "$source_name"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\r\n'
    return 0
  fi

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid | tr -d '\r\n'
    return 0
  fi

  err "failed to generate UUID (uuidgen and /proc/sys/kernel/random/uuid unavailable)"
  exit 1
}

resolve_auth_values() {
  # Generate once and persist into .env by write_env(), so restarts won't rotate.
  if [[ -z "$AUTH_UUID" ]]; then
    AUTH_UUID="$(gen_uuid)"
  fi
  if [[ -z "$HY2_PASSWORD" ]]; then
    HY2_PASSWORD="$AUTH_UUID"
  fi
  if [[ -z "$VLESS_UUID" ]]; then
    VLESS_UUID="$AUTH_UUID"
  fi
}

finalize_node_name() {
  if [[ -z "$NODE_NAME" ]]; then
    NODE_NAME="$(resolve_node_name)"
  else
    NODE_NAME="$(normalize_name "$NODE_NAME")"
  fi
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

detect_city_code() {
  local ip="$1"
  local city=""
  city="$(curl -fsSL "https://ipapi.co/${ip}/city/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/ //g' || true)"
  if [[ -z "$city" ]]; then
    city="$(curl -fsSL "https://ipwho.is/${ip}" 2>/dev/null | jq -r '.city // empty' | tr '[:upper:]' '[:lower:]' | sed 's/ //g' || true)"
  fi
  local code=""
  case "$city" in
    phoenix)            code="phx" ;;
    sanjose|san*jose)   code="sjc" ;;
    losangeles)         code="lax" ;;
    newyork)            code="nyc" ;;
    chicago)            code="chi" ;;
    dallas)             code="dfw" ;;
    seattle)            code="sea" ;;
    miami)              code="mia" ;;
    dubai)              code="dxb" ;;
    tokyo)              code="tyo" ;;
    osaka)              code="osa" ;;
    seoul)              code="sel" ;;
    chuncheon)          code="chc" ;;
    singapore)          code="sin" ;;
    london)             code="lon" ;;
    frankfurt)          code="fra" ;;
    *)                  code="${city:0:3}" ;;
  esac
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
    log "已更新 Cloudflare A 记录: $fqdn -> $ip"
  else
    curl -fsSL -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":$proxied}" \
      | jq -e '.success == true' >/dev/null
    log "已创建 Cloudflare A 记录: $fqdn -> $ip"
  fi
}

prepare_auto_domain() {
  if [[ "$AUTO_TLS" != "true" || "$AUTO_DOMAIN" != "true" ]]; then
    return 0
  fi
  [[ -n "$BASE_DOMAIN" ]] || { err "AUTO_DOMAIN=true 时必须填写 BASE_DOMAIN"; exit 1; }
  [[ -n "$CF_Token" ]] || { err "AUTO_DOMAIN=true 时必须填写 CF_Token"; exit 1; }
  need_cmd curl
  need_cmd jq

  local ip cpu mem country zone_id
  ip="$(get_public_ip)"
  [[ -n "$ip" ]] || { err "无法检测到公网 IPv4"; exit 1; }
  cpu="$(detect_cpu_flavor)"
  mem="$(detect_mem_label)"
  city="$(detect_city_code "$ip")"
  ip_suffix="${ip##*.}"
  TLS_DOMAIN="${cpu}${mem}-${ip_suffix}-${city}.${BASE_DOMAIN}"

  if [[ -n "$CF_Zone_ID" ]]; then
    zone_id="$CF_Zone_ID"
  else
    zone_id="$(resolve_zone_id "$BASE_DOMAIN" "$CF_Token")"
  fi
  [[ -n "$zone_id" ]] || { err "无法为 $BASE_DOMAIN 解析 Cloudflare zone id"; exit 1; }
  CF_Zone_ID="$zone_id"
  upsert_cloudflare_a_record "$TLS_DOMAIN" "$CF_Zone_ID" "$CF_Token" "$ip" "false"
  log "已选择自动域名: $TLS_DOMAIN"
}

validate_true_false() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *)
      err "$name 必须是 true 或 false，当前值: $value"
      exit 1
      ;;
  esac
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "已安装 docker: $(docker --version)"
    return 0
  fi

  log "未找到 docker，正在安装 docker engine"
  if [[ ! -f /etc/os-release ]]; then
    err "系统不受支持: 未找到 /etc/os-release"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  local distro="${ID:-}"
  local codename="${VERSION_CODENAME:-}"
  if [[ "$distro" != "ubuntu" && "$distro" != "debian" ]]; then
    err "自动安装不支持该系统: ${distro:-unknown} (仅支持 ubuntu/debian)"
    exit 1
  fi
  if [[ -z "$codename" ]]; then
    err "无法识别系统代号，无法配置 docker apt 源"
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
  APP_DIR="$(ask_input "部署目录" "$APP_DIR")"
  refresh_paths
  IMAGE="$(ask_input "镜像地址" "$IMAGE")"

  printf "\nTLS / 域名配置\n" >&2
  AUTO_TLS="$(normalize_bool "$(ask_choice "启用 AUTO_TLS (true/false)" "$AUTO_TLS")")"
  if [[ "$AUTO_TLS" == "true" ]]; then
    AUTO_DOMAIN="$(normalize_bool "$(ask_choice "自动生成子域名 (y/n)" "$AUTO_DOMAIN")")"
    if [[ "$AUTO_DOMAIN" == "true" ]]; then
      BASE_DOMAIN="$(ask_input "主域名 (example: 1100.ccwu.cc)" "$BASE_DOMAIN")"
    else
      TLS_DOMAIN="$(ask_input "TLS 域名 (AUTO_TLS=true 时必填)" "$TLS_DOMAIN")"
    fi
    CF_Token="$(ask_input "CF_Token (AUTO_TLS=true 时必填)" "$CF_Token")"
    ACME_EMAIL="$(ask_input "ACME_EMAIL (建议填写)" "$ACME_EMAIL")"
    CF_Account_ID="$(ask_input "CF_Account_ID (可选)" "$CF_Account_ID")"
    CF_Zone_ID="$(ask_input "CF_Zone_ID (可选)" "$CF_Zone_ID")"
  else
    AUTO_DOMAIN="false"
    TLS_DOMAIN="$(ask_input "TLS 域名 (手动证书模式用于节点链接)" "$TLS_DOMAIN")"
  fi

  printf "\n协议 / 端口配置\n" >&2
  ENABLE_HY2="$(normalize_bool "$(ask_choice "启用 HY2 (y/n 或 true/false)" "${ENABLE_HY2}")")"
  if [[ "$ENABLE_HY2" == "true" ]]; then
    HY2_PORT="$(ask_input "HY2 端口" "$HY2_PORT")"
  fi
  ENABLE_VLESS="$(normalize_bool "$(ask_choice "启用 VLESS (y/n 或 true/false)" "${ENABLE_VLESS}")")"
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    VLESS_PORT="$(ask_input "VLESS 端口" "$VLESS_PORT")"
  fi

  printf "\n可选参数\n" >&2
  AUTH_UUID="$(ask_input "AUTH_UUID (可选，留空自动生成)" "$AUTH_UUID")"
  HY2_PASSWORD="$(ask_input "HY2_PASSWORD (可选)" "$HY2_PASSWORD")"
  VLESS_UUID="$(ask_input "VLESS_UUID (可选)" "$VLESS_UUID")"
  WARP_LICENSE_KEY="$(ask_input "WARP_LICENSE_KEY (可选)" "$WARP_LICENSE_KEY")"
  TLS_ISSUE_RETRIES="$(ask_input "TLS 签发重试次数" "$TLS_ISSUE_RETRIES")"
  TLS_RENEW_INTERVAL="$(ask_input "TLS 续期间隔秒数" "$TLS_RENEW_INTERVAL")"
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    err "$name 必须是正整数，当前值: $value"
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
    err "至少要启用一种协议 (ENABLE_HY2/ENABLE_VLESS)"
    exit 1
  fi

  if [[ "$AUTO_TLS" == "true" ]]; then
    if [[ "$AUTO_DOMAIN" != "true" ]]; then
      [[ -n "$TLS_DOMAIN" ]] || { err "AUTO_TLS=true 且 AUTO_DOMAIN=false 时必须填写 TLS_DOMAIN"; exit 1; }
    fi
    [[ -n "$CF_Token" ]] || { err "AUTO_TLS=true 时必须填写 CF_Token"; exit 1; }
  else
    [[ -s "$APP_DIR/certs/fullchain.pem" ]] || {
      err "手动证书模式需要 $APP_DIR/certs/fullchain.pem"
      exit 1
    }
    [[ -s "$APP_DIR/certs/privkey.pem" ]] || {
      err "手动证书模式需要 $APP_DIR/certs/privkey.pem"
      exit 1
    }
  fi

  resolve_auth_values
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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
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
      - NODE_NAME=\${NODE_NAME:-}
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
NODE_NAME=$NODE_NAME
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
  log "初始化完成: $APP_DIR"
  log "下一步: 编辑 $ENV_FILE，然后运行: $0 deploy"
}

cmd_deploy() {
  need_cmd docker
  [[ -f "$COMPOSE_FILE" ]] || { err "缺少 compose 文件: $COMPOSE_FILE"; exit 1; }
  [[ -f "$ENV_FILE" ]] || { err "缺少环境变量文件: $ENV_FILE"; exit 1; }

  # shellcheck disable=SC1090
  source "$ENV_FILE"
  validate_config
  prepare_auto_domain
  finalize_node_name
  write_env
  record_current_image_for_rollback

  (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  )
  wait_healthy
  log "部署完成"
}

cmd_status() {
  need_cmd docker
  docker ps --format '{{.Names}} {{.Status}} {{.Image}}' | grep '^singbox-warp ' || {
    err "singbox-warp 容器未运行"
    exit 1
  }
  docker inspect singbox-warp --format 'ConfigImage={{.Config.Image}}'
  docker inspect singbox-warp --format 'ImageID={{.Image}}'
  docker inspect singbox-warp --format 'Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
}

cmd_show_nodes() {
  need_cmd docker
  need_cmd jq
  if ! docker ps --format '{{.Names}}' | grep -Fxq 'singbox-warp'; then
    err "未找到 singbox-warp 容器"
    exit 1
  fi

  local cfg
  local hy2_password hy2_port hy2_sni hy2_tag hy2_insecure
  local vless_uuid vless_port vless_sni vless_tag
  local node_name
  local has_any="false"
  local pass
  node_name="$(normalize_name "${NODE_NAME:-${TLS_DOMAIN:-node}}")"
  for pass in 1 2; do
    has_any="false"
    cfg="$(docker exec singbox-warp sh -c 'cat /etc/sing-box/config.json' 2>/dev/null || true)"
    if [[ -z "$cfg" ]]; then
      err "无法读取容器内的 /etc/sing-box/config.json"
      exit 1
    fi

    hy2_password="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="hysteria2") | .users[0].password // empty' | head -n1)"
    hy2_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' | head -n1)"
    hy2_sni="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.server_name // empty' | head -n1)"
    hy2_tag="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="hysteria2") | .tag // empty' | head -n1)"
    hy2_insecure="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="hysteria2") | if .tls.insecure then 1 else 0 end' | head -n1)"
    if [[ -n "$hy2_password" && -n "$hy2_port" && -n "$hy2_sni" ]]; then
      hy2_tag="${hy2_tag:-hy2-${node_name}}"
      echo "[node] hy2://${hy2_password}@${hy2_sni}:${hy2_port}?sni=${hy2_sni}&insecure=${hy2_insecure:-0}#${hy2_tag}"
      has_any="true"
    fi

    vless_uuid="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless") | .users[0].uuid // empty' | head -n1)"
    vless_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless") | .listen_port // empty' | head -n1)"
    vless_sni="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless") | .tls.server_name // empty' | head -n1)"
    vless_tag="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless") | .tag // empty' | head -n1)"
    if [[ -n "$vless_uuid" && -n "$vless_port" && -n "$vless_sni" ]]; then
      vless_tag="${vless_tag:-vless-${node_name}}"
      echo "[node] vless://${vless_uuid}@${vless_sni}:${vless_port}?encryption=none&security=tls&sni=${vless_sni}&type=tcp#${vless_tag}"
      has_any="true"
    fi

    if [[ "$has_any" == "true" ]]; then
      return 0
    fi

    if [[ "$pass" -eq 1 && -f "$ENV_FILE" ]]; then
      log "未解析到节点链接，自动执行一次部署刷新..."
      cmd_deploy || true
    fi
  done

  docker logs --tail 200 singbox-warp 2>/dev/null | grep -E '^\[node\] (hy2://|vless://)' || true
  err "无法从运行配置解析节点链接 (请先执行部署/更新并检查 TLS_DOMAIN)"
  exit 1
}

cmd_rollback() {
  need_cmd docker
  local rollback_image="${1:-}"
  if [[ -z "$rollback_image" ]]; then
    [[ -f "$ROLLBACK_FILE" ]] || {
      err "未找到回滚镜像。请手动传入: $0 rollback <image|digest>"
      exit 1
    }
    rollback_image="$(cat "$ROLLBACK_FILE")"
  fi

  [[ -f "$COMPOSE_FILE" ]] || { err "缺少 compose 文件: $COMPOSE_FILE"; exit 1; }
  sed -i -E "s#^(\s*image:\s*).+#\1${rollback_image}#" "$COMPOSE_FILE"
  (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  )
  wait_healthy
  log "回滚完成: $rollback_image"
}

cmd_bootstrap() {
  collect_bootstrap_inputs
  validate_config
  prepare_auto_domain
  finalize_node_name
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
  log "初始化部署完成: $APP_DIR"
}

main() {
  self_install_swd
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
    usage
    return 0
  fi
  if [[ -n "${1:-}" ]]; then
    err "此脚本仅支持交互模式，请不要带参数直接运行"
    usage
    exit 1
  fi
  action="$(ask_menu_choice)"
  case "$action" in
    1) cmd_bootstrap ;;
    2) cmd_show_nodes ;;
    3) cmd_status ;;
    4) log "退出" ;;
  esac
}

main "$@"
