#!/usr/bin/env bash
set -euo pipefail

APP_DIR_DEFAULT="/opt/singbox-warp"
ACTIVE_INSTANCE_FILE="${ACTIVE_INSTANCE_FILE:-/etc/singbox-warp/active-instance}"
IMAGE_DEFAULT="ghcr.io/caichengle666/singbox-warp-docker:latest"
COMPOSE_FILE_NAME="docker-compose.yml"
ENV_FILE_NAME=".env"
STATE_DIR_NAME=".deploy-state"

APP_DIR_EXPLICIT="${APP_DIR+x}"
APP_DIR="${APP_DIR:-$APP_DIR_DEFAULT}"
IMAGE="${IMAGE:-$IMAGE_DEFAULT}"
HY2_PORT="${HY2_PORT:-32443}"
VLESS_PORT="${VLESS_PORT:-38443}"
MIXED_PORT="${MIXED_PORT:-1080}"
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
CONFIG_BACKUP_DIR="$STATE_DIR/config-backup"
UPDATE_IMAGE_FILE="$STATE_DIR/update_image.txt"

refresh_paths() {
  COMPOSE_FILE="$APP_DIR/$COMPOSE_FILE_NAME"
  ENV_FILE="$APP_DIR/$ENV_FILE_NAME"
  STATE_DIR="$APP_DIR/$STATE_DIR_NAME"
  ROLLBACK_FILE="$STATE_DIR/last_image.txt"
  CONFIG_BACKUP_DIR="$STATE_DIR/config-backup"
  UPDATE_IMAGE_FILE="$STATE_DIR/update_image.txt"
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
  MIXED_PORT      默认 1080，仅绑定宿主机 127.0.0.1，给本机 HTTP+SOCKS5 代理使用
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

load_active_app_dir() {
  [[ -z "$APP_DIR_EXPLICIT" && -r "$ACTIVE_INSTANCE_FILE" ]] || return 0
  local saved_dir
  saved_dir="$(head -n1 "$ACTIVE_INSTANCE_FILE" | tr -d '\r\n')"
  if [[ "$saved_dir" == /* ]]; then
    APP_DIR="$saved_dir"
    refresh_paths
  else
    err "忽略无效的部署目录记录: $ACTIVE_INSTANCE_FILE"
  fi
}

persist_active_app_dir() {
  if is_root; then
    install -d -m 0755 "$(dirname "$ACTIVE_INSTANCE_FILE")"
    printf '%s\n' "$APP_DIR" > "$ACTIVE_INSTANCE_FILE"
    chmod 0644 "$ACTIVE_INSTANCE_FILE"
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -d -m 0755 "$(dirname "$ACTIVE_INSTANCE_FILE")"
    printf '%s\n' "$APP_DIR" | sudo tee "$ACTIVE_INSTANCE_FILE" >/dev/null
    sudo chmod 0644 "$ACTIVE_INSTANCE_FILE"
  else
    err "无法记录部署目录；以后请使用 APP_DIR=$APP_DIR swd"
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

ask_secret() {
  local prompt="$1"
  local current="${2:-}"
  local value=""
  if [[ -n "$current" ]]; then
    printf "%s [已配置，留空保持不变]: " "$prompt" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  if [[ "${FORCE_STDIN:-0}" == "1" ]]; then
    read -r value || { err "未能从 stdin 读取交互输入"; exit 1; }
  elif [[ -r /dev/tty ]]; then
    read -r -s value < /dev/tty || { err "未能从终端读取交互输入"; exit 1; }
    printf '\n' >&2
  else
    read -r value || { err "未检测到交互终端"; exit 1; }
  fi
  printf '%s' "${value:-$current}"
}

ask_menu_choice() {
  local value=""
  while true; do
    printf "\n请选择操作:\n" >&2
    printf "  1) 首次安装\n" >&2
    printf "  2) 更新镜像\n" >&2
    printf "  3) 修改配置\n" >&2
    printf "  4) 查看节点\n" >&2
    printf "  5) 查看状态\n" >&2
    printf "  6) 诊断检查\n" >&2
    printf "  7) 查看日志\n" >&2
    printf "  8) 重启服务\n" >&2
    printf "  9) 回滚镜像\n" >&2
    printf " 10) 退出\n" >&2
    printf "请输入 [1-10]: " >&2
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
      err "未输入内容，请输入 1-10"
      continue
    fi
    case "$value" in
      1|2|3|4|5|6|7|8|9|10)
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
    *)
      city="$(normalize_name "$city")"
      if [[ "$city" == "node" ]]; then
        code="x"
      else
        code="${city:0:3}"
      fi
      ;;
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

  local ip cpu mem city ip_suffix zone_id
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

ensure_host_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  command -v apt-get >/dev/null 2>&1 || {
    err "缺少命令: ${missing[*]}，请先手动安装"
    exit 1
  }
  log "正在安装必要工具: ${missing[*]}"
  run_root apt-get update -y
  run_root apt-get install -y "${missing[@]}"
}

load_existing_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    value="${value%$'\r'}"
    case "$key" in
      HY2_PORT|VLESS_PORT|MIXED_PORT|ENABLE_HY2|ENABLE_VLESS|AUTO_DOMAIN|BASE_DOMAIN|NODE_NAME|AUTH_UUID|HY2_PASSWORD|VLESS_UUID|AUTO_TLS|TLS_DOMAIN|TLS_CERT_PATH|TLS_KEY_PATH|ACME_EMAIL|TLS_ISSUE_RETRIES|TLS_RENEW_INTERVAL|WARP_LICENSE_KEY|CF_Token|CF_Account_ID|CF_Zone_ID)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$ENV_FILE"
}

collect_bootstrap_inputs() {
  local mode="${1:-install}"
  if [[ "$mode" == "install" ]]; then
    APP_DIR="$(ask_input "部署目录" "$APP_DIR")"
    refresh_paths
    if [[ -f "$ENV_FILE" || -f "$COMPOSE_FILE" ]]; then
      err "部署目录已有配置，请从主菜单选择 '修改配置'"
      return 1
    fi
  fi

  printf "\nTLS 配置\n" >&2
  AUTO_TLS="$(normalize_bool "$(ask_choice "启用自动 TLS (y/n)" "$AUTO_TLS")")"
  if [[ "$AUTO_TLS" == "true" ]]; then
    printf "需要 Cloudflare API Token（Zone / DNS / Edit 权限）。\n" >&2
    printf "申请地址: https://dash.cloudflare.com/profile/api-tokens\n" >&2
    CF_Token="$(ask_secret "Cloudflare API Token" "$CF_Token")"
    while [[ -z "$CF_Token" ]]; do
      CF_Token="$(ask_secret "Cloudflare API Token" "$CF_Token")"
      [[ -n "$CF_Token" ]] || err "Cloudflare API Token 不能为空"
    done
    AUTO_DOMAIN="$(normalize_bool "$(ask_choice "自动生成子域名 (y/n)" "$AUTO_DOMAIN")")"
    if [[ "$AUTO_DOMAIN" == "true" ]]; then
      BASE_DOMAIN="$(ask_input "Cloudflare 主域名 (example.com)" "$BASE_DOMAIN")"
      TLS_DOMAIN=""
    else
      TLS_DOMAIN="$(ask_input "TLS 域名" "$TLS_DOMAIN")"
    fi
    ACME_EMAIL="$(ask_input "证书通知邮箱 (建议填写)" "$ACME_EMAIL")"
  else
    AUTO_DOMAIN="false"
    CF_Token=""
    TLS_DOMAIN="$(ask_input "TLS 域名" "$TLS_DOMAIN")"
    printf "请将 fullchain.pem 和 privkey.pem 放入 %s/certs/\n" "$APP_DIR" >&2
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
  MIXED_PORT="$(ask_input "本机 Mixed 代理端口 (HTTP+SOCKS5，仅 127.0.0.1)" "$MIXED_PORT")"

  if [[ "$(normalize_bool "$(ask_choice "配置高级选项 (y/n)" "n")")" == "true" ]]; then
    IMAGE="$(ask_input "镜像地址" "$IMAGE")"
    AUTH_UUID="$(ask_input "AUTH_UUID (留空自动生成)" "$AUTH_UUID")"
    HY2_PASSWORD="$(ask_secret "HY2_PASSWORD (可选)" "$HY2_PASSWORD")"
    VLESS_UUID="$(ask_input "VLESS_UUID (可选)" "$VLESS_UUID")"
    WARP_LICENSE_KEY="$(ask_secret "WARP_LICENSE_KEY (可选)" "$WARP_LICENSE_KEY")"
    TLS_ISSUE_RETRIES="$(ask_input "TLS 签发重试次数" "$TLS_ISSUE_RETRIES")"
    TLS_RENEW_INTERVAL="$(ask_input "TLS 续期间隔秒数" "$TLS_RENEW_INTERVAL")"
  fi
}

confirm_config() {
  local domain_label="$TLS_DOMAIN"
  [[ "$AUTO_DOMAIN" == "true" ]] && domain_label="自动生成 (*.$BASE_DOMAIN)"
  printf "\n配置摘要\n" >&2
  printf "  部署目录: %s\n" "$APP_DIR" >&2
  printf "  TLS 域名: %s\n" "$domain_label" >&2
  if [[ "$AUTO_TLS" == "true" ]]; then
    printf "  Cloudflare Token: 已配置（不会显示）\n" >&2
  else
    printf "  TLS 模式: 手动证书\n" >&2
  fi
  printf "  HY2: %s (端口 %s)\n" "$ENABLE_HY2" "$HY2_PORT" >&2
  printf "  VLESS: %s (端口 %s)\n" "$ENABLE_VLESS" "$VLESS_PORT" >&2
  printf "  Mixed 端口: %s (仅本机)\n" "$MIXED_PORT" >&2
  [[ "$(normalize_bool "$(ask_choice "确认并继续 (y/n)" "y")")" == "true" ]]
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    err "$name 必须是正整数，当前值: $value"
    exit 1
  }
}

validate_port() {
  local name="$1"
  local value="$2"
  validate_positive_int "$name" "$value"
  (( 10#$value <= 65535 )) || {
    err "$name 必须在 1-65535 范围内，当前值: $value"
    exit 1
  }
}

validate_env_value() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9_./:@%+,-]*$ ]] || {
    err "$name 包含不支持的字符；请仅使用字母、数字及 _ . / : @ % + , -"
    exit 1
  }
}

validate_config() {
  validate_true_false "ENABLE_HY2" "$ENABLE_HY2"
  validate_true_false "ENABLE_VLESS" "$ENABLE_VLESS"
  validate_true_false "AUTO_DOMAIN" "$AUTO_DOMAIN"
  validate_bool "$AUTO_TLS"
  if [[ "$ENABLE_HY2" == "true" ]]; then
    validate_port "HY2_PORT" "$HY2_PORT"
  fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    validate_port "VLESS_PORT" "$VLESS_PORT"
  fi
  validate_port "MIXED_PORT" "$MIXED_PORT"
  validate_positive_int "TLS_ISSUE_RETRIES" "$TLS_ISSUE_RETRIES"
  validate_positive_int "TLS_RENEW_INTERVAL" "$TLS_RENEW_INTERVAL"
  validate_env_value "BASE_DOMAIN" "$BASE_DOMAIN"
  validate_env_value "TLS_DOMAIN" "$TLS_DOMAIN"
  validate_env_value "NODE_NAME" "$NODE_NAME"
  validate_env_value "ACME_EMAIL" "$ACME_EMAIL"
  validate_env_value "IMAGE" "$IMAGE"
  validate_env_value "TLS_CERT_PATH" "$TLS_CERT_PATH"
  validate_env_value "TLS_KEY_PATH" "$TLS_KEY_PATH"
  validate_env_value "AUTH_UUID" "$AUTH_UUID"
  validate_env_value "HY2_PASSWORD" "$HY2_PASSWORD"
  validate_env_value "VLESS_UUID" "$VLESS_UUID"
  validate_env_value "WARP_LICENSE_KEY" "$WARP_LICENSE_KEY"
  validate_env_value "CF_Token" "$CF_Token"
  validate_env_value "CF_Account_ID" "$CF_Account_ID"
  validate_env_value "CF_Zone_ID" "$CF_Zone_ID"
  if [[ "$ENABLE_HY2" != "true" && "$ENABLE_VLESS" != "true" ]]; then
    err "至少要启用一种协议 (ENABLE_HY2/ENABLE_VLESS)"
    exit 1
  fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    local effective_vless_uuid="${VLESS_UUID:-$AUTH_UUID}"
    if [[ -n "$effective_vless_uuid" ]] &&
       ! [[ "$effective_vless_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      err "VLESS_UUID/AUTH_UUID 不是有效的 UUID"
      exit 1
    fi
  fi
  if [[ "$ENABLE_HY2" == "true" && "$MIXED_PORT" == "$HY2_PORT" ]] ||
     [[ "$ENABLE_VLESS" == "true" && "$MIXED_PORT" == "$VLESS_PORT" ]] ||
     [[ "$ENABLE_HY2" == "true" && "$ENABLE_VLESS" == "true" && "$HY2_PORT" == "$VLESS_PORT" ]]; then
    err "HY2、VLESS 和 Mixed 端口不能重复"
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
  ports_block="${ports_block}
      - \"127.0.0.1:\${MIXED_PORT:-1080}:\${MIXED_PORT:-1080}/tcp\""

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
      test: ["CMD-SHELL", "test -s /run/sing-box.pid && kill -0 \"\$(cat /run/sing-box.pid)\" && curl -fsS --max-time 3 --proxy \"socks5h://127.0.0.1:\${MIXED_PORT:-1080}\" https://cp.cloudflare.com/ >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      - HY2_PORT=\${HY2_PORT:-32443}
      - VLESS_PORT=\${VLESS_PORT:-38443}
      - MIXED_PORT=\${MIXED_PORT:-1080}
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
MIXED_PORT=$MIXED_PORT
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
  chmod 600 "$ENV_FILE"
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
  if docker inspect singbox-warp >/dev/null 2>&1; then
    local image_id repo_digest configured_image
    image_id="$(docker inspect singbox-warp --format '{{.Image}}')"
    configured_image="$(docker inspect singbox-warp --format '{{.Config.Image}}')"
    if [[ "$configured_image" != sha256:* && "$configured_image" != *@sha256:* ]]; then
      printf '%s\n' "$configured_image" >"$UPDATE_IMAGE_FILE"
    fi
    repo_digest="$(docker image inspect "$image_id" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
    if [[ -n "$repo_digest" && "$repo_digest" != "<no value>" ]]; then
      printf '%s\n' "$repo_digest" >"$ROLLBACK_FILE"
    else
      printf '%s\n' "$image_id" >"$ROLLBACK_FILE"
    fi
  elif [[ -f "$COMPOSE_FILE" ]]; then
    grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n1 | sed -E 's/^\s*image:\s*//' >"$ROLLBACK_FILE" || true
  fi
}

backup_config() {
  mkdir -p "$CONFIG_BACKUP_DIR"
  cp -f "$ENV_FILE" "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME"
  cp -f "$COMPOSE_FILE" "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME"
}

restore_config() {
  [[ -f "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" && -f "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" ]] || {
    err "没有可恢复的配置备份"
    return 1
  }
  cp -f "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" "$ENV_FILE"
  cp -f "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" "$COMPOSE_FILE"
  chmod 600 "$ENV_FILE"
  (
    cd "$APP_DIR"
    docker compose up -d
  )
  log "已恢复修改前的配置"
}

wait_healthy() {
  local attempts="${1:-30}"
  local i s
  for i in $(seq 1 "$attempts"); do
    s="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' singbox-warp 2>/dev/null || true)"
    log "health check $i/$attempts: $s"
    if [[ "$s" == "healthy" ]]; then
      return 0
    fi
    sleep 2
  done
  err "container is not healthy"
  docker ps --format '{{.Names}} {{.Status}} {{.Image}}' | grep '^singbox-warp ' || true
  docker logs --tail 80 singbox-warp || true
  return 1
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
  local vless_uuid vless_port vless_sni vless_tag vless_flow vless_link
  local node_name
  local has_any="false"
  node_name="$(normalize_name "${NODE_NAME:-${TLS_DOMAIN:-node}}")"
  cfg="$(docker exec singbox-warp sh -c 'cat /etc/sing-box/config.json' 2>/dev/null || true)"
  if [[ -z "$cfg" ]]; then
    err "无法读取容器内的 /etc/sing-box/config.json"
    return 1
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
  vless_flow="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless") | .users[0].flow // empty' | head -n1)"
  if [[ -n "$vless_uuid" && -n "$vless_port" && -n "$vless_sni" ]]; then
    vless_tag="${vless_tag:-vless-${node_name}}"
    vless_link="vless://${vless_uuid}@${vless_sni}:${vless_port}?encryption=none&security=tls&sni=${vless_sni}&type=tcp"
    if [[ -n "$vless_flow" ]]; then
      vless_link="${vless_link}&flow=${vless_flow}"
    fi
    echo "[node] ${vless_link}#${vless_tag}"
    has_any="true"
  fi

  [[ "$has_any" == "true" ]] && return 0
  err "无法从运行配置解析节点链接；该操作不会自动修改或重启服务"
  return 1
}

replace_compose_image() {
  local image="$1"
  validate_env_value "IMAGE" "$image"
  awk -v replacement="$image" '
    /^[[:space:]]*image:[[:space:]]*/ {
      match($0, /^[[:space:]]*image:[[:space:]]*/)
      print substr($0, 1, RLENGTH) replacement
      next
    }
    { print }
  ' "$COMPOSE_FILE" >"$COMPOSE_FILE.tmp"
  mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
}

apply_rollback_image() {
  local rollback_image="$1"
  [[ -f "$COMPOSE_FILE" ]] || { err "缺少 compose 文件: $COMPOSE_FILE"; exit 1; }
  replace_compose_image "$rollback_image"
  if ! docker image inspect "$rollback_image" >/dev/null 2>&1; then
    docker pull "$rollback_image"
  fi
  (
    cd "$APP_DIR"
    docker compose up -d
  )
  wait_healthy || return 1
  log "回滚完成: $rollback_image"
}

cmd_rollback() {
  need_cmd docker
  [[ -s "$ROLLBACK_FILE" ]] || {
    err "未找到可回滚的镜像记录，请先执行一次 '更新镜像'"
    return 1
  }
  apply_rollback_image "$(cat "$ROLLBACK_FILE")"
}

cmd_bootstrap() {
  collect_bootstrap_inputs install
  validate_config
  confirm_config || { log "已取消安装"; return 0; }
  ensure_docker
  ensure_host_tools
  prepare_auto_domain
  finalize_node_name

  mkdir -p "$APP_DIR"/{data,certs,acme}
  write_compose
  write_env

  (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  )
  wait_healthy 180 || {
    err "首次安装未通过健康检查，请根据上方日志修正配置后重试"
    return 1
  }
  persist_active_app_dir
  log "初始化部署完成: $APP_DIR"
}

cmd_update_image() {
  need_cmd docker
  [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || {
    err "未找到现有部署，请先执行首次安装"
    return 1
  }
  if [[ -s "$UPDATE_IMAGE_FILE" ]] && grep -Eq '^[[:space:]]*image:[[:space:]]*([^[:space:]]+@sha256:|sha256:)' "$COMPOSE_FILE"; then
    replace_compose_image "$(head -n1 "$UPDATE_IMAGE_FILE")"
  fi
  record_current_image_for_rollback
  if ! (
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
  ); then
    err "镜像更新失败，正在恢复旧镜像"
    apply_rollback_image "$(cat "$ROLLBACK_FILE")"
    return 1
  fi
  if ! wait_healthy; then
    err "新镜像健康检查失败，正在恢复旧镜像"
    apply_rollback_image "$(cat "$ROLLBACK_FILE")"
    return 1
  fi
  log "镜像更新完成，现有配置未改变"
}

cmd_edit_config() {
  [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]] || {
    err "未找到现有部署，请先执行首次安装"
    return 1
  }
  load_existing_env
  collect_bootstrap_inputs edit
  validate_config
  confirm_config || { log "已取消修改"; return 0; }
  backup_config
  ensure_docker
  ensure_host_tools
  prepare_auto_domain
  finalize_node_name
  write_compose
  write_env
  if ! (
    cd "$APP_DIR"
    docker compose up -d
  ); then
    err "应用新配置失败，正在恢复旧配置"
    restore_config || true
    return 1
  fi
  if ! wait_healthy; then
    err "新配置健康检查失败，正在恢复旧配置"
    restore_config || true
    wait_healthy || true
    return 1
  fi
  log "配置修改完成"
}

DIAG_FAILURES=0

diag_ok() { printf '[OK]   %s\n' "$*"; }
diag_warn() { printf '[WARN] %s\n' "$*"; }
diag_fail() {
  printf '[FAIL] %s\n' "$*"
  DIAG_FAILURES=$((DIAG_FAILURES + 1))
}

cmd_diagnose() {
  DIAG_FAILURES=0
  printf '\n诊断检查（只读）\n'
  printf '部署目录: %s\n\n' "$APP_DIR"

  if [[ -f "$ENV_FILE" ]]; then diag_ok ".env 存在"; else diag_fail "缺少 $ENV_FILE"; fi
  if [[ -f "$COMPOSE_FILE" ]]; then diag_ok "Compose 文件存在"; else diag_fail "缺少 $COMPOSE_FILE"; fi
  command -v docker >/dev/null 2>&1 || {
    diag_fail "Docker 未安装"
    return 1
  }

  if [[ -f "$ENV_FILE" ]]; then
    load_existing_env
  fi
  if [[ -f "$COMPOSE_FILE" ]] && (cd "$APP_DIR" && docker compose config -q >/dev/null 2>&1); then
    diag_ok "Compose 配置有效"
  else
    diag_fail "Compose 配置无效"
  fi

  if docker inspect singbox-warp >/dev/null 2>&1; then
    local running health
    running="$(docker inspect singbox-warp --format '{{.State.Running}}')"
    health="$(docker inspect singbox-warp --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    if [[ "$running" == "true" ]]; then diag_ok "容器正在运行"; else diag_fail "容器未运行"; fi
    if [[ "$health" == "healthy" ]]; then diag_ok "容器健康检查通过"; else diag_fail "容器健康状态: $health"; fi
  else
    diag_fail "未找到 singbox-warp 容器"
  fi

  if [[ -n "$TLS_DOMAIN" ]]; then
    if command -v getent >/dev/null 2>&1 && getent ahostsv4 "$TLS_DOMAIN" >/dev/null 2>&1; then
      diag_ok "域名可解析: $TLS_DOMAIN"
    else
      diag_warn "无法确认域名解析: $TLS_DOMAIN"
    fi
  else
    diag_fail "TLS_DOMAIN 为空"
  fi

  if [[ -n "$CF_Token" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    if curl -fsSL --max-time 10 -H "Authorization: Bearer $CF_Token" \
      https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null \
      | jq -e '.success == true and .result.status == "active"' >/dev/null 2>&1; then
      diag_ok "Cloudflare API Token 有效"
    else
      diag_fail "Cloudflare API Token 无效或网络不可达"
    fi
  else
    diag_warn "未检查 Cloudflare Token（Token、curl 或 jq 缺失）"
  fi

  if docker exec singbox-warp test -s "$TLS_CERT_PATH" >/dev/null 2>&1; then
    local cert_end
    cert_end="$(docker exec singbox-warp openssl x509 -in "$TLS_CERT_PATH" -noout -enddate 2>/dev/null || true)"
    if docker exec singbox-warp openssl x509 -in "$TLS_CERT_PATH" -checkend 2592000 -noout >/dev/null 2>&1; then
      diag_ok "TLS 证书有效期超过 30 天 (${cert_end#notAfter=})"
    else
      diag_warn "TLS 证书将在 30 天内到期 (${cert_end#notAfter=})"
    fi
  else
    diag_fail "容器内未找到 TLS 证书"
  fi

  if command -v curl >/dev/null 2>&1; then
    local warp_ip
    warp_ip="$(curl -fsSL --max-time 10 --proxy "socks5h://127.0.0.1:$MIXED_PORT" https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$warp_ip" ]]; then diag_ok "Mixed/WARP 出口可用: $warp_ip"; else diag_warn "无法通过 Mixed 代理获取出口 IP"; fi
  fi

  printf '\n'
  if [[ "$DIAG_FAILURES" -eq 0 ]]; then
    diag_ok "未发现阻断性问题"
    return 0
  fi
  printf '[FAIL] 发现 %s 个阻断性问题\n' "$DIAG_FAILURES"
  return 1
}

cmd_logs() {
  need_cmd docker
  docker logs --tail 100 -f singbox-warp || true
}

cmd_restart() {
  need_cmd docker
  docker restart singbox-warp >/dev/null
  wait_healthy || return 1
  log "服务重启完成"
}

main() {
  load_active_app_dir
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
  while true; do
    action="$(ask_menu_choice)"
    case "$action" in
      1) cmd_bootstrap || true ;;
      2) cmd_update_image || true ;;
      3) cmd_edit_config || true ;;
      4) cmd_show_nodes || true ;;
      5) cmd_status || true ;;
      6) cmd_diagnose || true ;;
      7) cmd_logs ;;
      8) cmd_restart || true ;;
      9) cmd_rollback || true ;;
      10) log "退出"; return 0 ;;
    esac
  done
}

main "$@"
