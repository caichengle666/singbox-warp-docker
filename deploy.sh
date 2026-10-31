#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2.5.1"
APP_DIR_DEFAULT="/opt/singbox-warp"
ACTIVE_INSTANCE_FILE="${ACTIVE_INSTANCE_FILE:-/etc/singbox-warp/active-instance}"
IMAGE_DEFAULT="ghcr.io/caichengle666/singbox-warp-docker:latest"
DEPLOY_SCRIPT_URL="${DEPLOY_SCRIPT_URL:-https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh}"
COMPOSE_FILE_NAME="docker-compose.yml"
ENV_FILE_NAME=".env"
STATE_DIR_NAME=".deploy-state"

APP_DIR_EXPLICIT="${APP_DIR+x}"
APP_DIR="${APP_DIR:-$APP_DIR_DEFAULT}"
IMAGE="${IMAGE:-$IMAGE_DEFAULT}"
HY2_PORT="${HY2_PORT:-32443}"
HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-false}"
HY2_HOP_PORTS="${HY2_HOP_PORTS:-}"
HY2_HOP_PORTS_LEGACY_ALLOWED="false"
VLESS_PORT="${VLESS_PORT:-38443}"
ANYTLS_PORT="${ANYTLS_PORT:-4443}"
SS_PORT="${SS_PORT:-48443}"
MIXED_PORT="${MIXED_PORT:-1080}"
ENABLE_HY2="${ENABLE_HY2:-true}"
ENABLE_VLESS="${ENABLE_VLESS:-true}"
ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
ENABLE_SS="${ENABLE_SS:-false}"
TUIC_PORT="${TUIC_PORT:-36443}"
ENABLE_TUIC="${ENABLE_TUIC:-false}"
REALITY_PORT="${REALITY_PORT:-443}"
ENABLE_REALITY="${ENABLE_REALITY:-false}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
# DEPLOY_MODE=direct: 公网端口直连（默认）；tunnel: 只开 VLESS-WS，由 cloudflared 隧道进入
DEPLOY_MODE="${DEPLOY_MODE:-direct}"
ENABLE_WS="${ENABLE_WS:-false}"
WS_PORT="${WS_PORT:-8080}"
WS_PATH="${WS_PATH:-}"
WS_HOST="${WS_HOST:-}"
WS_ADDRESS="${WS_ADDRESS:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
CF_TUNNEL_PROTOCOL="${CF_TUNNEL_PROTOCOL:-auto}"
CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"
TUIC_PASSWORD="${TUIC_PASSWORD:-}"
WARP_SCOPE="${WARP_SCOPE:-all}"
WARP_SPLIT_GEOSITE="${WARP_SPLIT_GEOSITE-openai,anthropic,google-gemini,netflix,disney}"
WARP_SPLIT_DOMAINS="${WARP_SPLIT_DOMAINS:-}"
AUTO_TLS="${AUTO_TLS:-false}"
AUTO_DOMAIN="${AUTO_DOMAIN:-true}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
TLS_DOMAIN="${TLS_DOMAIN:-}"
NODE_NAME="${NODE_NAME:-}"
AUTH_UUID="${AUTH_UUID:-}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
VLESS_UUID="${VLESS_UUID:-}"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"
SS_PASSWORD="${SS_PASSWORD:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}"
TLS_KEY_PATH="${TLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}"
TLS_ISSUE_RETRIES="${TLS_ISSUE_RETRIES:-3}"
TLS_RENEW_INTERVAL="${TLS_RENEW_INTERVAL:-43200}"
CITY_LOOKUP_RETRIES="${CITY_LOOKUP_RETRIES:-3}"
CITY_LOOKUP_TIMEOUT="${CITY_LOOKUP_TIMEOUT:-8}"
CITY_LOOKUP_RETRY_DELAY="${CITY_LOOKUP_RETRY_DELAY:-1}"
WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
WARP_MODE="${WARP_MODE:-auto}"
WARP_AUTORECOVER="${WARP_AUTORECOVER:-true}"
WARP_PROBE_INTERVAL="${WARP_PROBE_INTERVAL:-60}"
USQUE_HTTP2="${USQUE_HTTP2:-true}"
CF_Token="${CF_Token:-}"
CF_Account_ID="${CF_Account_ID:-}"
CF_Zone_ID="${CF_Zone_ID:-}"

COMPOSE_FILE="$APP_DIR/$COMPOSE_FILE_NAME"
ENV_FILE="$APP_DIR/$ENV_FILE_NAME"
STATE_DIR="$APP_DIR/$STATE_DIR_NAME"
ROLLBACK_FILE="$STATE_DIR/last_image.txt"
CONFIG_BACKUP_DIR="$STATE_DIR/config-backup"
UPDATE_IMAGE_FILE="$STATE_DIR/update_image.txt"
BACKUP_DIR="$APP_DIR/backups"

refresh_paths() {
  COMPOSE_FILE="$APP_DIR/$COMPOSE_FILE_NAME"
  ENV_FILE="$APP_DIR/$ENV_FILE_NAME"
  STATE_DIR="$APP_DIR/$STATE_DIR_NAME"
  ROLLBACK_FILE="$STATE_DIR/last_image.txt"
  CONFIG_BACKUP_DIR="$STATE_DIR/config-backup"
  UPDATE_IMAGE_FILE="$STATE_DIR/update_image.txt"
  BACKUP_DIR="$APP_DIR/backups"
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
  local source_file="${BASH_SOURCE[0]:-}" target="/usr/local/bin/swd"
  if [[ ! -f "$source_file" ]]; then
    return 0
  fi
  if [[ ! -w "/usr/local/bin" ]]; then
    return 0
  fi
  cp -f "$source_file" "$target" 2>/dev/null || return 0
  chmod +x "$target" 2>/dev/null || true
}

usage() {
  printf 'singbox-warp manager v%s\n\n' "$SCRIPT_VERSION"
  cat <<'EOF'
Usage:
  deploy.sh
  deploy.sh guide       打印申请指南（Cloudflare 域名、API Token、Tunnel token、WARP+）
  deploy.sh --version

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
  HY2_PORT_HOPPING true/false，默认 false
  HY2_HOP_PORTS   端口跳跃范围，例如 40000-40100
  VLESS_PORT      默认 38443
  ANYTLS_PORT     默认 4443
  SS_PORT         默认 48443
  ENABLE_TUIC     true/false，默认 false（TUIC v5，UDP）
  TUIC_PORT       默认 36443
  ENABLE_REALITY  true/false，默认 false（VLESS-Reality，不需要证书）
  REALITY_PORT    默认 443
  REALITY_SNI     Reality 伪装站点，默认 www.microsoft.com
  DEPLOY_MODE     direct/tunnel，默认 direct；tunnel 适合没有公网入站端口的机器
  ENABLE_WS       true/false，VLESS-WS 入站（隧道模式自动开启，不需要证书）
  WS_PORT         默认 8080，只在 Docker 内网监听
  WS_PATH         留空自动生成随机路径
  WS_HOST         隧道的公网域名，用于生成节点链接
  WS_ADDRESS      可选，客户端实际连接的地址（优选 IP/域名）
  CF_TUNNEL_TOKEN 隧道模式必填，Cloudflare Tunnel token
  CF_TUNNEL_PROTOCOL auto/quic/http2，默认 auto
  WARP_SCOPE      all/split，默认 all；split 时只有指定站点走 WARP
  WARP_SPLIT_GEOSITE 逗号分隔的 geosite 名称，默认 openai,anthropic,google-gemini,netflix,disney
  WARP_SPLIT_DOMAINS 逗号分隔的额外域名后缀，可选
  MIXED_PORT      默认 1080，仅绑定宿主机 127.0.0.1，给本机 HTTP+SOCKS5 代理使用
  AUTH_UUID       可选，固定认证值
  HY2_PASSWORD    可选，覆盖 HY2 密码
  VLESS_UUID      可选，覆盖 VLESS UUID
  ANYTLS_PASSWORD 可选，留空时使用 AUTH_UUID
  SS_PASSWORD     可选，留空时自动生成 Shadowsocks 2022 密钥

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

ensure_root() {
  if is_root; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    err "此操作需要 root 权限，但系统未安装 sudo；请切换到 root 后重新运行"
    exit 1
  fi
  local source_file="${BASH_SOURCE[0]:-}"
  if [[ ! -f "$source_file" ]]; then
    err "无法从管道自动提升权限；请先下载脚本再运行: curl -fsSL $DEPLOY_SCRIPT_URL -o deploy.sh && bash deploy.sh"
    exit 1
  fi
  log "检测到当前用户不是 root，正在通过 sudo 请求权限"
  if ! sudo -n -E true && ! sudo -v; then
    err "sudo 授权失败"
    exit 1
  fi
  # shellcheck disable=SC2093
  exec sudo -E bash "$source_file" "$@"
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
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  printf '%s' "${value:-$current}"
}

ask_menu_choice() {
  local value=""
  while true; do
    printf "\nsingbox-warp 管理器 v%s\n请选择操作:\n" "$SCRIPT_VERSION" >&2
    printf "  1) 首次安装\n" >&2
    printf "  2) 更新镜像\n" >&2
    printf "  3) 更新管理脚本\n" >&2
    printf "  4) 修改配置\n" >&2
    printf "  5) 查看节点 / 二维码\n" >&2
    printf "  6) 状态总览\n" >&2
    printf "  7) 诊断检查\n" >&2
    printf "  8) 查看日志\n" >&2
    printf "  9) 重启服务\n" >&2
    printf " 10) 创建备份\n" >&2
    printf " 11) 恢复备份\n" >&2
    printf " 12) 自动更新设置\n" >&2
    printf " 13) 回滚镜像\n" >&2
    printf " 14) 卸载服务\n" >&2
    printf " 15) 申请指南（域名 / Token / 隧道 / WARP+）\n" >&2
    printf " 16) 退出\n" >&2
    printf "请输入 [1-16]: " >&2
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
      err "未输入内容，请输入 1-16"
      continue
    fi
    case "$value" in
      1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16)
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
  if [[ "$ENABLE_ANYTLS" == "true" && -z "$ANYTLS_PASSWORD" ]]; then
    ANYTLS_PASSWORD="$AUTH_UUID"
  fi
  if [[ "$ENABLE_TUIC" == "true" && -z "$TUIC_PASSWORD" ]]; then
    TUIC_PASSWORD="$AUTH_UUID"
  fi
  if [[ "$ENABLE_SS" == "true" && -z "$SS_PASSWORD" ]]; then
    need_cmd openssl
    SS_PASSWORD="$(openssl rand -base64 32 | tr -d '\r\n')"
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
  ip="$(curl -fsSL --connect-timeout 3 --max-time 8 --retry 2 --retry-delay 1 --retry-max-time 20 \
    https://api.ipify.org 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsSL --connect-timeout 3 --max-time 8 --retry 2 --retry-delay 1 --retry-max-time 20 \
      https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  fi
  if is_valid_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

is_valid_ipv4() {
  local ip="$1" octet
  local -a octets
  IFS='.' read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

normalize_city_value() {
  local city
  city="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' \
    | sed -E 's/[^a-z0-9]+//g')"
  case "$city" in
    ""|unknown|unavailable|ratelimitexceeded|error|null)
      return 1
      ;;
  esac
  printf '%s' "$city"
}

lookup_city_ipapi() {
  local response
  command -v jq >/dev/null 2>&1 || return 1
  response="$(curl -fsSL --connect-timeout 3 --max-time "$CITY_LOOKUP_TIMEOUT" \
    --retry 0 "http://ip-api.com/json/$1?fields=status,city" 2>/dev/null || true)"
  normalize_city_value "$(printf '%s' "$response" | jq -er \
    'select(.status == "success") | .city // empty' 2>/dev/null || true)"
}

lookup_city_ipwho() {
  local response
  command -v jq >/dev/null 2>&1 || return 1
  response="$(curl -fsSL --connect-timeout 3 --max-time "$CITY_LOOKUP_TIMEOUT" \
    --retry 0 "https://ipwho.is/$1" 2>/dev/null || true)"
  normalize_city_value "$(printf '%s' "$response" | jq -er \
    'select(.success != false) | .city // empty' 2>/dev/null || true)"
}

lookup_city_ipinfo() {
  local response
  command -v jq >/dev/null 2>&1 || return 1
  response="$(curl -fsSL --connect-timeout 3 --max-time "$CITY_LOOKUP_TIMEOUT" \
    --retry 0 "https://ipinfo.io/$1/json" 2>/dev/null || true)"
  normalize_city_value "$(printf '%s' "$response" | jq -er \
    '.city // empty' 2>/dev/null || true)"
}

detect_city_code() {
  local ip="$1"
  local city="" attempt
  if ! is_valid_ipv4 "$ip"; then
    return 1
  fi

  for ((attempt=1; attempt<=CITY_LOOKUP_RETRIES; attempt++)); do
    city="$(lookup_city_ipapi "$ip" 2>/dev/null || true)"
    [[ -n "$city" ]] && break
    city="$(lookup_city_ipwho "$ip" 2>/dev/null || true)"
    [[ -n "$city" ]] && break
    city="$(lookup_city_ipinfo "$ip" 2>/dev/null || true)"
    [[ -n "$city" ]] && break
    if ((attempt < CITY_LOOKUP_RETRIES)); then
      sleep "$CITY_LOOKUP_RETRY_DELAY"
    fi
  done

  if [[ -z "$city" ]]; then
    return 1
  fi
  local code=""
  case "$city" in
    phoenix)             code="phx" ;;
    sanjose)             code="sjc" ;;
    sanfrancisco)        code="sfo" ;;
    losangeles)          code="lax" ;;
    newyork|newyorkcity) code="nyc" ;;
    lasvegas)            code="las" ;;
    chicago)             code="chi" ;;
    dallas)              code="dfw" ;;
    seattle)             code="sea" ;;
    miami)               code="mia" ;;
    dubai)               code="dxb" ;;
    tokyo)               code="tyo" ;;
    osaka)               code="osa" ;;
    seoul)               code="sel" ;;
    chuncheon)           code="chc" ;;
    singapore)           code="sin" ;;
    london)              code="lon" ;;
    frankfurt)           code="fra" ;;
    *)                   code="${city:0:3}" ;;
  esac
  [[ "$code" =~ ^[a-z][a-z0-9]{0,2}$ ]] || return 1
  printf '%s' "$code"
}



resolve_zone_id() {
  local zone_name="$1"
  local token="$2"
  local response zid
  response="$(curl -fsSL --connect-timeout 5 --max-time 15 --get \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    --data-urlencode "name=$zone_name" --data-urlencode "status=active" \
    "https://api.cloudflare.com/client/v4/zones")" || return 1
  printf '%s' "$response" | jq -e '.success == true' >/dev/null || {
    err "Cloudflare zone 查询失败: $zone_name"
    return 1
  }
  zid="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
  printf '%s' "$zid"
}

upsert_cloudflare_a_record() {
  local fqdn="$1"
  local zone_id="$2"
  local token="$3"
  local ip="$4"
  local proxied="${5:-false}"
  local record_response record_id body response
  case "$proxied" in
    true|false) ;;
    *) err "无效的 Cloudflare proxied 值: $proxied"; return 1 ;;
  esac
  record_response="$(curl -fsSL --connect-timeout 5 --max-time 15 --get \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    --data-urlencode "type=A" --data-urlencode "name=$fqdn" \
    "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records")" || return 1
  printf '%s' "$record_response" | jq -e '.success == true' >/dev/null || {
    err "查询 Cloudflare A 记录失败: $fqdn"
    return 1
  }
  record_id="$(printf '%s' "$record_response" | jq -r '.result[0].id // empty')"
  body="$(jq -nc --arg type A --arg name "$fqdn" --arg content "$ip" --argjson proxied "$proxied" \
    '{type:$type,name:$name,content:$content,ttl:120,proxied:$proxied}')"

  if [[ -n "$record_id" ]]; then
    response="$(curl -fsSL --connect-timeout 5 --max-time 15 -X PUT \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      --data-binary "$body" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id")" || return 1
    printf '%s' "$response" | jq -e '.success == true' >/dev/null || {
      err "Cloudflare 更新 A 记录失败: $fqdn -> $ip"
      return 1
    }
    log "已更新 Cloudflare A 记录: $fqdn -> $ip"
  else
    response="$(curl -fsSL --connect-timeout 5 --max-time 15 -X POST \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      --data-binary "$body" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records")" || return 1
    printf '%s' "$response" | jq -e '.success == true' >/dev/null || {
      err "Cloudflare 创建 A 记录失败: $fqdn -> $ip"
      return 1
    }
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
  city="$(detect_city_code "$ip" || printf 'x')"
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
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  command -v apt-get >/dev/null 2>&1 || {
    err "缺少命令: ${missing[*]}，请先手动安装"
    exit 1
  }
  log "正在安装必要工具: ${missing[*]}"
  run_root apt-get update -y
  run_root apt-get install -y "${missing[@]}"
}

# ---------------------------------------------------------------------------
# 申请指南：Cloudflare 账号/域名、API Token、Tunnel token、WARP+ 按键。
# 新手常卡在「去哪申请、选什么权限、复制哪一段」，这里把链接和步骤直接打印出来。
# 所有输出走 stderr，不影响 ask_* 的返回值。
# ---------------------------------------------------------------------------
GUIDE_CF_SIGNUP_URL="https://dash.cloudflare.com/sign-up"
GUIDE_CF_ADD_SITE_URL="https://developers.cloudflare.com/fundamentals/manage-domains/add-site/"
GUIDE_CF_DOMAINS_URL="https://domains.cloudflare.com/"
GUIDE_CF_API_TOKEN_URL="https://dash.cloudflare.com/profile/api-tokens"
GUIDE_CF_TUNNELS_URL="https://dash.cloudflare.com/?to=/:account/tunnels"
GUIDE_CF_TUNNEL_DOC_URL="https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/"
GUIDE_WARP_APP_URL="https://one.one.one.one/"
GUIDE_REPO_URL="https://github.com/caichengle666/singbox-warp-docker"

guide_title() {
  printf '\n==================== %s ====================\n' "$1" >&2
}

guide_line() {
  printf '%s\n' "$@" >&2
}

guide_domain() {
  guide_title "准备：托管在 Cloudflare 的域名"
  guide_line \
    "  1. 注册 Cloudflare 免费账号: $GUIDE_CF_SIGNUP_URL" \
    "  2. 登录后点 Add a domain（添加域名），输入你的域名，选 Free 免费计划" \
    "  3. 到域名注册商后台，把 NS（域名服务器）改成 Cloudflare 给的两个" \
    "  4. 等 Cloudflare 里域名状态变成 Active（通常几分钟，最长 24 小时）" \
    "  图文说明: $GUIDE_CF_ADD_SITE_URL" \
    "  还没有域名: 可以在 $GUIDE_CF_DOMAINS_URL 或任意注册商购买"
}

guide_api_token() {
  guide_title "申请 Cloudflare API Token（用于自动签证书、自动建 DNS 记录）"
  guide_line \
    "  1. 打开: $GUIDE_CF_API_TOKEN_URL" \
    "  2. 点 Create Token -> 选模板 Edit zone DNS（编辑区域 DNS）-> Use template" \
    "  3. Permissions 保留 Zone / DNS / Edit，再点 Add more 加一行 Zone / Zone / Read" \
    "  4. Zone Resources 选 Include / Specific zone / 你的域名" \
    "  5. 点 Continue to summary -> Create Token，复制显示的 Token（只显示一次）" \
    "  注意: 要的是 API Token，不是 Global API Key；粘贴时不要带空格"
}

guide_tunnel() {
  local port="${1:-$WS_PORT}"
  guide_title "申请 Cloudflare Tunnel token"
  guide_line \
    "  前提: 域名已托管在 Cloudflare（还没有的话先看菜单 15「申请指南」里的域名部分）" \
    "  1. 打开: $GUIDE_CF_TUNNELS_URL" \
    "     （登录后进入 Networking -> Tunnels；旧版界面在 Zero Trust -> Networks -> Tunnels）" \
    "  2. 点 Create a tunnel，类型选 Cloudflared，起个名字后保存" \
    "  3. 安装页面选 Docker，复制命令里 --token 后面那一长串（eyJ 开头）" \
    "     整条命令直接粘贴进来也可以，脚本会自动提取；不需要在本机运行那条命令" \
    "  4. 继续到 Routes（旧版叫 Public Hostname）-> Add route -> Published application:" \
    "       Subdomain: 例如 node      Domain: 选你的域名" \
    "       Service URL: http://singbox-warp:${port}" \
    "     （旧版界面: Service Type 选 HTTP，URL 填 singbox-warp:${port}）" \
    "  5. 保存。建议用一级子域名（node.example.com），多级子域名免费证书不覆盖，会握手失败" \
    "  官方图文: $GUIDE_CF_TUNNEL_DOC_URL"
}

guide_warp_license() {
  guide_title "WARP+ 按键（可选）"
  guide_line \
    "  不填就用免费 WARP，绝大多数场景够用。有 WARP+ 订阅才需要填：" \
    "  1. 手机安装 1.1.1.1 App: $GUIDE_WARP_APP_URL" \
    "  2. 菜单 -> 账户（Account）-> 按键（Key），复制那串 xxxxxxxx-xxxxxxxx-xxxxxxxx" \
    "  注意: 一个按键最多绑定 5 台设备，本机会占用其中一个名额"
}

guide_checklist() {
  local mode="${1:-direct}"
  guide_title "开始前请准备"
  if [[ "$mode" == "tunnel" ]]; then
    guide_line \
      "  [ ] 一个托管在 Cloudflare 的域名" \
      "  [ ] 一个 Cloudflare Tunnel token，并给隧道加好 Published application 路由" \
      "  本机不需要开放任何入站端口，也不需要证书" \
      "  不知道怎么申请: 下面会打印步骤；输入框里输入 ? 可再次查看"
  else
    guide_line \
      "  [ ] 一个托管在 Cloudflare 的域名（用于自动签证书）" \
      "  [ ] 一个 Cloudflare API Token（Zone / DNS / Edit + Zone / Zone / Read）" \
      "  [ ] 云服务器安全组/防火墙放行你要启用的协议端口（HY2、TUIC 是 UDP）" \
      "  不知道怎么申请: 下面会打印步骤；输入框里输入 ? 可再次查看"
  fi
}

cmd_guide() {
  guide_line "singbox-warp 申请指南 v$SCRIPT_VERSION    项目主页: $GUIDE_REPO_URL"
  guide_domain
  guide_api_token
  guide_tunnel "$WS_PORT"
  guide_warp_license
  guide_line ""
}

# 和 ask_input 一样，但输入 ? 时打印对应指南并重新提问。
ask_input_guided() {
  local prompt="$1" default="$2" guide_fn="$3" value
  while true; do
    value="$(ask_input "$prompt（输入 ? 查看申请步骤）" "$default")"
    if [[ "$value" == "?" || "$value" == "？" ]]; then
      "$guide_fn"
      continue
    fi
    printf '%s' "$value"
    return 0
  done
}

trim_value() {
  printf '%s' "$1" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# 用户常把整条安装命令（cloudflared service install eyJ... / --token eyJ...）粘进来，
# 这里取出真正的 token；没有 eyJ 开头的片段时原样返回（去掉首尾空白和引号）。
extract_tunnel_token() {
  local raw word token=""
  local -a words=()
  raw="$(trim_value "$1")"
  read -r -a words <<<"$raw" || true
  for word in "${words[@]}"; do
    word="${word#--token=}"
    word="${word//\"/}"
    word="${word//\'/}"
    [[ "$word" == eyJ* ]] && token="$word"
  done
  if [[ -z "$token" ]]; then
    token="${raw//\"/}"
    token="${token//\'/}"
  fi
  printf '%s' "$token"
}

# 远程管理隧道的 token 是 base64 的 JSON：{"a":账号ID,"t":隧道ID,"s":密钥}。
# 能解出来就打印隧道 ID，解不出来返回 1。
tunnel_token_id() {
  local token="$1" padded json id
  [[ "$token" =~ ^[A-Za-z0-9+/_=-]{40,}$ ]] || return 1
  padded="$(printf '%s' "$token" | tr '_-' '/+')"
  case $(( ${#padded} % 4 )) in
    2) padded="${padded}==" ;;
    3) padded="${padded}=" ;;
    1) return 1 ;;
  esac
  json="$(printf '%s' "$padded" | base64 -d 2>/dev/null)" || return 1
  [[ "$json" == *'"a"'* && "$json" == *'"s"'* ]] || return 1
  id="$(printf '%s' "$json" | sed -nE 's/.*"t"[[:space:]]*:[[:space:]]*"([0-9a-fA-F-]{36})".*/\1/p')"
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

CF_CHECK_ERROR=""
CF_CHECK_ZONE=""
CF_CHECK_ZONE_ID=""

# 在线检查 Cloudflare API Token 能否看到并编辑 $2 所在的 zone。
# 返回 0 = 可用（zone 在 CF_CHECK_ZONE / CF_CHECK_ZONE_ID）；1 = 明确不可用（原因在 CF_CHECK_ERROR）；
# 2 = 无法检查（网络/工具缺失）。结果放在全局变量里，调用方不要用 $(...) 包它。
cf_token_check() {
  local token="$1" name="$2" candidate resp zid status
  CF_CHECK_ERROR=""
  CF_CHECK_ZONE=""
  CF_CHECK_ZONE_ID=""
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 2
  [[ -n "$token" && -n "$name" ]] || return 2
  candidate="${name%.}"
  while [[ "$candidate" == *.* ]]; do
    resp="$(curl -sS --connect-timeout 5 --max-time 15 --get \
      -H "Authorization: Bearer $token" \
      --data-urlencode "name=$candidate" \
      "https://api.cloudflare.com/client/v4/zones" 2>/dev/null)" || return 2
    printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 || return 2
    if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
      CF_CHECK_ERROR="Token 无效或权限不足（$(printf '%s' "$resp" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null)）"
      return 1
    fi
    zid="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
    if [[ -n "$zid" ]]; then
      CF_CHECK_ZONE="$candidate"
      status="$(printf '%s' "$resp" | jq -r '.result[0].status // empty')"
      if [[ "$status" != "active" ]]; then
        CF_CHECK_ERROR="域名 $candidate 在 Cloudflare 的状态是 ${status:-unknown}，还没生效；请先到注册商把 NS 改成 Cloudflare 的，等状态变成 Active"
        return 1
      fi
      resp="$(curl -sS --connect-timeout 5 --max-time 15 --get \
        -H "Authorization: Bearer $token" --data-urlencode "per_page=1" \
        "https://api.cloudflare.com/client/v4/zones/$zid/dns_records" 2>/dev/null)" || return 2
      if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
        CF_CHECK_ERROR="Token 能看到 $candidate，但没有 DNS 权限；请给 Token 加上 Zone / DNS / Edit"
        return 1
      fi
      CF_CHECK_ZONE_ID="$zid"
      return 0
    fi
    candidate="${candidate#*.}"
  done
  CF_CHECK_ERROR="Token 有效，但看不到 $name 所在的域名；请确认域名已加到 Cloudflare，并且 Token 的 Zone Resources 包含它（还需要 Zone / Zone / Read 权限）"
  return 1
}

# 交互式核对 Token；明确失败时打印原因和指南，让用户重填或坚持继续。
# 返回 0 = 通过或用户选择继续；1 = 用户要重填。
confirm_cf_token() {
  local domain="$1" rc=0
  log "正在在线检查 Cloudflare API Token..."
  cf_token_check "$CF_Token" "$domain" || rc=$?
  case "$rc" in
    0)
      log "Token 可用，域名 $CF_CHECK_ZONE 已就绪"
      [[ "$AUTO_DOMAIN" == "true" && -z "$CF_Zone_ID" ]] && CF_Zone_ID="$CF_CHECK_ZONE_ID"
      return 0
      ;;
    2)
      log "暂时无法在线检查 Token（网络或工具缺失），跳过检查继续"
      return 0
      ;;
  esac
  err "$CF_CHECK_ERROR"
  guide_api_token
  [[ "$CF_CHECK_ERROR" == *"NS"* || "$CF_CHECK_ERROR" == *"加到 Cloudflare"* ]] && guide_domain
  if [[ "$(normalize_bool "$(ask_choice "重新输入 Token 和域名 (y=重填 / n=忽略并继续)" "y")")" == "true" ]]; then
    return 1
  fi
  log "已忽略 Token 检查，证书签发可能失败"
  return 0
}

# 隧道部署后从公网走一遍：域名 -> Cloudflare -> 隧道 -> sing-box WS。
# 只给出提示，不回滚。
probe_tunnel_hostname() {
  [[ "$DEPLOY_MODE" == "tunnel" && -n "$WS_HOST" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local ws_path code i
  ws_path="$(docker exec singbox-warp sh -c 'cat /etc/sing-box/config.json' 2>/dev/null |
    jq -r '.inbounds[]? | select((.transport.type // "") == "ws") | .transport.path // empty' 2>/dev/null | head -n1 || true)"
  [[ -n "$ws_path" ]] || ws_path="/"
  log "正在从公网检查 https://$WS_HOST ..."
  for i in $(seq 1 8); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --http1.1 --max-time 8 \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "https://${WS_HOST}${ws_path}" 2>/dev/null || true)"
    [[ "$code" == "101" ]] && { log "公网访问正常: https://$WS_HOST 已通过隧道连到节点"; return 0; }
    sleep 5
  done
  case "$code" in
    000|"")
      err "无法访问 https://$WS_HOST：域名没解析或 HTTPS 握手失败"
      guide_line "  - 隧道里还没加 Published application 路由，或域名填错了" \
        "  - 用了多级子域名（a.b.example.com），免费证书不覆盖，请换成一级子域名" ;;
    502|504)
      err "隧道已连上，但 Cloudflare 连不到节点（HTTP $code）"
      guide_line "  - 隧道路由的 Service URL 必须是 http://singbox-warp:$WS_PORT（不是 https，也不是 localhost）" ;;
    530|1033)
      err "域名没有指向这个隧道（HTTP $code）"
      guide_line "  - 在隧道的 Routes 里添加 Published application，域名填 $WS_HOST" ;;
    404)
      err "请求到了别的服务（HTTP 404）；请确认 $WS_HOST 路由到的是这个隧道，Service URL 为 http://singbox-warp:$WS_PORT" ;;
    *)
      err "公网检查未通过（HTTP $code）" ;;
  esac
  guide_line "  隧道设置入口: $GUIDE_CF_TUNNELS_URL" \
    "  改好后无需重装，在菜单里选「诊断检查」再测一次"
  return 0
}

cmd_update_script() {
  need_cmd curl
  local temp_file target remote_version
  temp_file="$(mktemp)"
  target="/usr/local/bin/swd"
  if ! curl -fsSL "$DEPLOY_SCRIPT_URL" -o "$temp_file"; then
    rm -f "$temp_file"
    err "管理脚本下载失败"
    return 1
  fi
  if ! bash -n "$temp_file"; then
    rm -f "$temp_file"
    err "下载的管理脚本语法校验失败，未替换现有脚本"
    return 1
  fi
  remote_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$temp_file" | head -n1)"
  if [[ -z "$remote_version" ]]; then
    rm -f "$temp_file"
    err "下载的管理脚本缺少有效 SCRIPT_VERSION，未替换现有脚本"
    return 1
  fi
  if [[ -f "$target" ]] && [[ "$remote_version" == "$SCRIPT_VERSION" ]] && cmp -s "$temp_file" "$target"; then
    rm -f "$temp_file"
    log "管理脚本已是最新版本: v$SCRIPT_VERSION"
    return 0
  fi
  if [[ "$remote_version" != "$SCRIPT_VERSION" ]]; then
    log "发现新版本: v$SCRIPT_VERSION -> v$remote_version"
  fi
  if ! run_root install -m 0755 "$temp_file" "$target"; then
    rm -f "$temp_file"
    err "写入管理脚本失败: $target"
    return 1
  fi
  rm -f "$temp_file"
  log "管理脚本已更新: $target（下次运行可用 --version 查看版本）"
}

load_existing_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    value="${value%$'\r'}"
    case "$key" in
      HY2_PORT|HY2_PORT_HOPPING|HY2_HOP_PORTS|VLESS_PORT|ANYTLS_PORT|SS_PORT|MIXED_PORT|ENABLE_HY2|ENABLE_VLESS|ENABLE_ANYTLS|ENABLE_SS|TUIC_PORT|ENABLE_TUIC|TUIC_PASSWORD|REALITY_PORT|ENABLE_REALITY|REALITY_SNI|REALITY_SHORT_ID|WARP_SCOPE|WARP_SPLIT_GEOSITE|WARP_SPLIT_DOMAINS|AUTO_DOMAIN|BASE_DOMAIN|NODE_NAME|AUTH_UUID|HY2_PASSWORD|VLESS_UUID|ANYTLS_PASSWORD|SS_PASSWORD|AUTO_TLS|TLS_DOMAIN|TLS_CERT_PATH|TLS_KEY_PATH|ACME_EMAIL|TLS_ISSUE_RETRIES|TLS_RENEW_INTERVAL|WARP_LICENSE_KEY|WARP_MODE|WARP_AUTORECOVER|WARP_PROBE_INTERVAL|USQUE_HTTP2|CF_Token|CF_Account_ID|CF_Zone_ID|DEPLOY_MODE|ENABLE_WS|WS_PORT|WS_PATH|WS_HOST|WS_ADDRESS|CF_TUNNEL_TOKEN|CF_TUNNEL_PROTOCOL|CLOUDFLARED_IMAGE)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$ENV_FILE"
  if [[ "$HY2_HOP_PORTS" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
    local hop_start=$((10#${BASH_REMATCH[1]})) hop_end=$((10#${BASH_REMATCH[2]}))
    if (( hop_end >= hop_start && hop_end - hop_start + 1 > 50 )); then
      HY2_HOP_PORTS_LEGACY_ALLOWED="true"
    fi
  fi
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

  printf "\n部署模式\n" >&2
  printf "direct = 公网端口直连（HY2/VLESS/TUIC 等，需要证书）\n" >&2
  printf "tunnel = 隧道模式，只开 VLESS-WS，通过 Cloudflare Tunnel 进入（适合没有公网入站端口的机器）\n" >&2
  DEPLOY_MODE="$(ask_input "部署模式 (direct/tunnel)" "$DEPLOY_MODE")"
  while [[ "$DEPLOY_MODE" != "direct" && "$DEPLOY_MODE" != "tunnel" ]]; do
    err "部署模式只能是 direct 或 tunnel"
    DEPLOY_MODE="$(ask_input "部署模式 (direct/tunnel)" "direct")"
  done
  if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
    collect_tunnel_inputs "$mode"
    return 0
  fi
  ENABLE_WS="false"

  [[ "$mode" == "install" ]] && guide_checklist direct
  printf "\n自动 TLS 配置\n" >&2
  [[ -n "$CF_Token" ]] || { guide_domain; guide_api_token; }
  AUTO_TLS="true"
  while true; do
    printf "Cloudflare API Token 将明文显示，输入后请确认终端没有旁观者。\n" >&2
    CF_Token="$(trim_value "$(ask_input_guided "Cloudflare API Token (可见输入)" "$CF_Token" guide_api_token)")"
    while [[ -z "$CF_Token" ]]; do
      err "Cloudflare API Token 不能为空"
      CF_Token="$(trim_value "$(ask_input_guided "Cloudflare API Token (可见输入)" "$CF_Token" guide_api_token)")"
    done
    AUTO_DOMAIN="$(normalize_bool "$(ask_choice "自动生成子域名 (y/n)" "$AUTO_DOMAIN")")"
    if [[ "$AUTO_DOMAIN" == "true" ]]; then
      BASE_DOMAIN="$(trim_value "$(ask_input_guided "Cloudflare 主域名 (example.com)" "$BASE_DOMAIN" guide_domain)")"
      while [[ -z "$BASE_DOMAIN" ]]; do
        err "主域名不能为空"
        BASE_DOMAIN="$(trim_value "$(ask_input_guided "Cloudflare 主域名 (example.com)" "$BASE_DOMAIN" guide_domain)")"
      done
      TLS_DOMAIN=""
      CF_Zone_ID=""
      confirm_cf_token "$BASE_DOMAIN" && break
    else
      TLS_DOMAIN="$(trim_value "$(ask_input_guided "TLS 域名 (例如 node.example.com)" "$TLS_DOMAIN" guide_domain)")"
      while [[ -z "$TLS_DOMAIN" ]]; do
        err "TLS 域名不能为空"
        TLS_DOMAIN="$(trim_value "$(ask_input_guided "TLS 域名 (例如 node.example.com)" "$TLS_DOMAIN" guide_domain)")"
      done
      confirm_cf_token "$TLS_DOMAIN" && break
    fi
  done
  ACME_EMAIL="$(ask_input "证书通知邮箱 (建议填写)" "$ACME_EMAIL")"

  printf "\n协议 / 端口配置\n" >&2
  ENABLE_HY2="$(normalize_bool "$(ask_choice "启用 HY2 (y/n 或 true/false)" "${ENABLE_HY2}")")"
  if [[ "$ENABLE_HY2" == "true" ]]; then
    HY2_PORT="$(ask_input "HY2 端口" "$HY2_PORT")"
    HY2_PORT_HOPPING="$(normalize_bool "$(ask_choice "启用 HY2 端口跳跃 (y/n 或 true/false)" "${HY2_PORT_HOPPING}")")"
    if [[ "$HY2_PORT_HOPPING" == "true" ]]; then
      [[ -n "$HY2_HOP_PORTS" ]] || log "HY2 跳跃端口范围将自动选择（最多 50 个端口）"
    else
      HY2_HOP_PORTS=""
    fi
  fi
  ENABLE_VLESS="$(normalize_bool "$(ask_choice "启用 VLESS (y/n 或 true/false)" "${ENABLE_VLESS}")")"
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    VLESS_PORT="$(ask_input "VLESS 端口" "$VLESS_PORT")"
  fi
  ENABLE_ANYTLS="$(normalize_bool "$(ask_choice "启用 AnyTLS (y/n 或 true/false)" "${ENABLE_ANYTLS}")")"
  if [[ "$ENABLE_ANYTLS" == "true" ]]; then
    ANYTLS_PORT="$(ask_input "AnyTLS 端口" "$ANYTLS_PORT")"
  fi
  ENABLE_SS="$(normalize_bool "$(ask_choice "启用 Shadowsocks (y/n 或 true/false)" "${ENABLE_SS}")")"
  if [[ "$ENABLE_SS" == "true" ]]; then
    SS_PORT="$(ask_input "Shadowsocks 端口" "$SS_PORT")"
  fi
  ENABLE_TUIC="$(normalize_bool "$(ask_choice "启用 TUIC v5 (y/n 或 true/false)" "${ENABLE_TUIC}")")"
  if [[ "$ENABLE_TUIC" == "true" ]]; then
    TUIC_PORT="$(ask_input "TUIC 端口 (UDP)" "$TUIC_PORT")"
  fi
  ENABLE_REALITY="$(normalize_bool "$(ask_choice "启用 VLESS-Reality (y/n 或 true/false)" "${ENABLE_REALITY}")")"
  if [[ "$ENABLE_REALITY" == "true" ]]; then
    REALITY_PORT="$(ask_input "Reality 端口" "$REALITY_PORT")"
    REALITY_SNI="$(ask_input "Reality 伪装站点 (需支持 TLS 1.3)" "$REALITY_SNI")"
  fi

  collect_warp_inputs

  if [[ "$(normalize_bool "$(ask_choice "配置高级选项 (y/n)" "n")")" == "true" ]]; then
    IMAGE="$(ask_input "镜像地址" "$IMAGE")"
    AUTH_UUID="$(ask_input "AUTH_UUID (留空自动生成)" "$AUTH_UUID")"
    HY2_PASSWORD="$(ask_secret "HY2_PASSWORD (可选)" "$HY2_PASSWORD")"
    VLESS_UUID="$(ask_input "VLESS_UUID (可选)" "$VLESS_UUID")"
    guide_warp_license
    WARP_LICENSE_KEY="$(ask_secret "WARP_LICENSE_KEY (可选，留空用免费 WARP)" "$WARP_LICENSE_KEY")"
    TLS_ISSUE_RETRIES="$(ask_input "TLS 签发重试次数" "$TLS_ISSUE_RETRIES")"
    TLS_RENEW_INTERVAL="$(ask_input "TLS 续期间隔秒数" "$TLS_RENEW_INTERVAL")"
  fi
}

collect_warp_inputs() {
  printf "\nWARP 分流\n" >&2
  printf "all = 全部流量走 WARP；split = 只有指定站点走 WARP，其余直连。\n" >&2
  WARP_SCOPE="$(ask_input "WARP 范围 (all/split)" "$WARP_SCOPE")"
  if [[ "$WARP_SCOPE" == "split" ]]; then
    WARP_SPLIT_GEOSITE="$(ask_input "走 WARP 的 geosite (逗号分隔)" "$WARP_SPLIT_GEOSITE")"
    WARP_SPLIT_DOMAINS="$(ask_input "额外走 WARP 的域名后缀 (逗号分隔，可留空)" "$WARP_SPLIT_DOMAINS")"
  fi
  MIXED_PORT="$(ask_input "本机 Mixed 代理端口 (HTTP+SOCKS5，仅 127.0.0.1)" "$MIXED_PORT")"
}

# 隧道模式只需要 tunnel token 和公网域名；其它入站全部关闭，也不需要证书。
collect_tunnel_inputs() {
  ENABLE_WS="true"
  ENABLE_HY2="false"
  ENABLE_VLESS="false"
  ENABLE_ANYTLS="false"
  ENABLE_SS="false"
  ENABLE_TUIC="false"
  ENABLE_REALITY="false"
  HY2_PORT_HOPPING="false"
  HY2_HOP_PORTS=""
  AUTO_TLS="false"
  AUTO_DOMAIN="false"

  local mode="${1:-install}" raw tunnel_id
  [[ "$mode" == "install" ]] && guide_checklist tunnel
  printf "\n隧道配置\n" >&2
  [[ -n "$CF_TUNNEL_TOKEN" ]] || guide_tunnel "$WS_PORT"
  printf "Tunnel token 将明文显示，输入后请确认终端没有旁观者。\n" >&2
  while true; do
    raw="$(ask_input_guided "Cloudflare Tunnel token (可见输入，可粘贴整条安装命令)" "$CF_TUNNEL_TOKEN" guide_tunnel)"
    CF_TUNNEL_TOKEN="$(extract_tunnel_token "$raw")"
    if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
      err "Tunnel token 不能为空"
      continue
    fi
    if tunnel_id="$(tunnel_token_id "$CF_TUNNEL_TOKEN")"; then
      log "已识别隧道 ID: $tunnel_id"
      break
    fi
    err "这不像 Tunnel token：应是 eyJ 开头的一长串（在隧道安装命令 --token 后面）"
    guide_tunnel "$WS_PORT"
    if [[ "$(normalize_bool "$(ask_choice "仍然使用这个 token (y/n)" "n")")" == "true" ]]; then
      break
    fi
    # 不把填错的值当默认值，避免直接回车又用上它
    CF_TUNNEL_TOKEN=""
  done
  while true; do
    WS_HOST="$(trim_value "$(ask_input_guided "隧道公网域名 (隧道路由里填的域名，例如 node.example.com)" "$WS_HOST" guide_tunnel)")"
    WS_HOST="${WS_HOST#https://}"
    WS_HOST="${WS_HOST#http://}"
    WS_HOST="${WS_HOST%%/*}"
    if [[ -z "$WS_HOST" ]]; then
      err "隧道公网域名不能为空"
    elif [[ ! "$WS_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
      err "域名格式不对: $WS_HOST"
    else
      break
    fi
  done
  if [[ "$(tr -cd '.' <<<"$WS_HOST" | wc -c)" -ge 3 ]]; then
    log "提示: $WS_HOST 看起来是多级子域名；Cloudflare 免费证书只覆盖一级子域名（node.example.com），多级会握手失败"
  fi
  WS_PORT="$(ask_input "WS 端口 (仅 Docker 内网，需与隧道 Service URL 一致)" "$WS_PORT")"
  log "请确认隧道路由的 Service URL 是: http://singbox-warp:$WS_PORT"
  WS_ADDRESS="$(trim_value "$(ask_input "客户端连接地址 (优选 IP/域名，可留空)" "$WS_ADDRESS")")"

  collect_warp_inputs

  if [[ "$(normalize_bool "$(ask_choice "配置高级选项 (y/n)" "n")")" == "true" ]]; then
    IMAGE="$(ask_input "镜像地址" "$IMAGE")"
    AUTH_UUID="$(ask_input "AUTH_UUID (留空自动生成)" "$AUTH_UUID")"
    WS_PATH="$(ask_input "WS 路径 (留空自动生成)" "$WS_PATH")"
    CF_TUNNEL_PROTOCOL="$(ask_input "隧道协议 (auto/quic/http2)" "$CF_TUNNEL_PROTOCOL")"
    guide_warp_license
    WARP_LICENSE_KEY="$(ask_secret "WARP_LICENSE_KEY (可选，留空用免费 WARP)" "$WARP_LICENSE_KEY")"
  fi
}

confirm_config() {
  if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
    printf "\n配置摘要（隧道模式）\n" >&2
    printf "  部署目录: %s\n" "$APP_DIR" >&2
    printf "  公网域名: %s\n" "$WS_HOST" >&2
    printf "  WS 端口: %s (仅 Docker 内网)\n" "$WS_PORT" >&2
    printf "  WS 路径: %s\n" "${WS_PATH:-自动生成}" >&2
    if [[ -n "$WS_ADDRESS" ]]; then printf "  客户端连接地址: %s\n" "$WS_ADDRESS" >&2; fi
    printf "  Tunnel token: 已配置（不会显示）\n" >&2
    printf "  隧道协议: %s\n" "$CF_TUNNEL_PROTOCOL" >&2
    printf "  WARP 范围: %s%s\n" "$WARP_SCOPE" "$([[ "$WARP_SCOPE" == "split" ]] && printf ' (%s %s)' "$WARP_SPLIT_GEOSITE" "$WARP_SPLIT_DOMAINS")" >&2
    printf "  Mixed 端口: %s (仅本机)\n" "$MIXED_PORT" >&2
    [[ "$(normalize_bool "$(ask_choice "确认并继续 (y/n)" "y")")" == "true" ]]
    return
  fi
  local domain_label="$TLS_DOMAIN"
  [[ "$AUTO_DOMAIN" == "true" ]] && domain_label="自动生成 (*.$BASE_DOMAIN)"
  printf "\n配置摘要\n" >&2
  printf "  部署目录: %s\n" "$APP_DIR" >&2
  printf "  TLS 域名: %s\n" "$domain_label" >&2
  printf "  Cloudflare Token: 已配置（不会显示）\n" >&2
  printf "  HY2: %s (端口 %s)\n" "$ENABLE_HY2" "$HY2_PORT" >&2
  printf "  HY2 端口跳跃: %s%s\n" "$HY2_PORT_HOPPING" "${HY2_HOP_PORTS:+ (范围 $HY2_HOP_PORTS)}" >&2
  printf "  VLESS: %s (端口 %s)\n" "$ENABLE_VLESS" "$VLESS_PORT" >&2
  printf "  AnyTLS: %s (端口 %s)\n" "$ENABLE_ANYTLS" "$ANYTLS_PORT" >&2
  printf "  Shadowsocks: %s (端口 %s)\n" "$ENABLE_SS" "$SS_PORT" >&2
  printf "  TUIC: %s (端口 %s/udp)\n" "$ENABLE_TUIC" "$TUIC_PORT" >&2
  printf "  Reality: %s (端口 %s, SNI %s)\n" "$ENABLE_REALITY" "$REALITY_PORT" "$REALITY_SNI" >&2
  printf "  WARP 范围: %s%s\n" "$WARP_SCOPE" "$([[ "$WARP_SCOPE" == "split" ]] && printf ' (%s %s)' "$WARP_SPLIT_GEOSITE" "$WARP_SPLIT_DOMAINS")" >&2
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

validate_secret_value() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9_./:@%+,=-]*$ ]] || {
    err "$name 包含不支持的字符"
    exit 1
  }
}

validate_token_value() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9_./:@%+,=-]+$ ]] || {
    err "$name 包含不支持的字符；请确认没有复制首尾空格或换行"
    exit 1
  }
}

validate_hy2_hop_ports() {
  [[ "$HY2_PORT_HOPPING" == "true" ]] || return 0
  [[ "$ENABLE_HY2" == "true" ]] || { err "启用 HY2 端口跳跃前必须启用 HY2"; exit 1; }
  [[ "$HY2_HOP_PORTS" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] || {
    err "HY2_HOP_PORTS 必须是起始端口-结束端口，例如 40000-40100"
    exit 1
  }
  local start=$((10#${BASH_REMATCH[1]})) end=$((10#${BASH_REMATCH[2]}))
  validate_port "HY2_HOP_PORTS 起始端口" "$start"
  validate_port "HY2_HOP_PORTS 结束端口" "$end"
  (( start < end )) || { err "HY2_HOP_PORTS 起始端口必须小于结束端口"; exit 1; }
  if (( end - start + 1 > 50 )); then
    if [[ "$HY2_HOP_PORTS_LEGACY_ALLOWED" == "true" ]] && (( end - start + 1 <= 1024 )); then
      log "检测到旧版 HY2 跳跃范围 $HY2_HOP_PORTS，保留兼容；新配置最多允许 50 个端口"
    else
      err "HY2_HOP_PORTS 最多允许 50 个端口"
      exit 1
    fi
  fi
  local port
  for ((port=start; port<=end; port++)); do
    [[ "$port" != "$HY2_PORT" && "$port" != "$MIXED_PORT" ]] || {
      err "HY2 跳跃端口范围不能包含 HY2_PORT 或 MIXED_PORT: $port"
      exit 1
    }
    [[ "$ENABLE_VLESS" != "true" || "$port" != "$VLESS_PORT" ]] || { err "HY2 跳跃端口范围与 VLESS_PORT 冲突: $port"; exit 1; }
    [[ "$ENABLE_ANYTLS" != "true" || "$port" != "$ANYTLS_PORT" ]] || { err "HY2 跳跃端口范围与 ANYTLS_PORT 冲突: $port"; exit 1; }
    [[ "$ENABLE_SS" != "true" || "$port" != "$SS_PORT" ]] || { err "HY2 跳跃端口范围与 SS_PORT 冲突: $port"; exit 1; }
    [[ "$ENABLE_TUIC" != "true" || "$port" != "$TUIC_PORT" ]] || { err "HY2 跳跃端口范围与 TUIC_PORT 冲突: $port"; exit 1; }
    [[ "$ENABLE_REALITY" != "true" || "$port" != "$REALITY_PORT" ]] || { err "HY2 跳跃端口范围与 REALITY_PORT 冲突: $port"; exit 1; }
  done
}

scan_host_ports() {
  local -n used_ports_ref="$1"
  local proc_file local_address port_hex port
  used_ports_ref=()
  for proc_file in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    [[ -r "$proc_file" ]] || continue
    while read -r _ local_address _ _ _; do
      port_hex="${local_address##*:}"
      [[ "$port_hex" =~ ^[0-9A-Fa-f]{4}$ ]] || continue
      port=$((16#$port_hex))
      (( port > 0 )) && used_ports_ref[$port]=1
    done < <(tail -n +2 "$proc_file")
  done
}

select_hy2_hop_ports() {
  [[ "$HY2_PORT_HOPPING" == "true" && -z "$HY2_HOP_PORTS" ]] || return 0
  [[ "$ENABLE_HY2" == "true" ]] || { err "启用 HY2 端口跳跃前必须启用 HY2"; exit 1; }

  local -A used_ports=()
  scan_host_ports used_ports
  used_ports[$HY2_PORT]=1
  used_ports[$MIXED_PORT]=1
  [[ "$ENABLE_VLESS" == "true" ]] && used_ports[$VLESS_PORT]=1
  [[ "$ENABLE_ANYTLS" == "true" ]] && used_ports[$ANYTLS_PORT]=1
  [[ "$ENABLE_SS" == "true" ]] && used_ports[$SS_PORT]=1
  [[ "$ENABLE_TUIC" == "true" ]] && used_ports[$TUIC_PORT]=1
  [[ "$ENABLE_REALITY" == "true" ]] && used_ports[$REALITY_PORT]=1

  local min_port=20000 max_start=59951 start port attempt random_value
  for ((attempt=1; attempt<=2000; attempt++)); do
    random_value="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')"
    [[ "$random_value" =~ ^[0-9]+$ ]] || random_value="$RANDOM"
    start=$((min_port + random_value % (max_start - min_port + 1)))
    for ((port=start; port<start+50; port++)); do
      [[ -z "${used_ports[$port]+x}" ]] || break
    done
    (( port == start + 50 )) || continue
    HY2_HOP_PORTS="$start-$((start + 49))"
    validate_hy2_hop_ports
    local -A verify_ports=()
    scan_host_ports verify_ports
    for ((port=start; port<start+50; port++)); do
      [[ -z "${verify_ports[$port]+x}" ]] || {
        err "自动选择的 HY2 跳跃端口在落盘前被占用: $port"
        exit 1
      }
    done
    return 0
  done
  err "无法自动找到连续 50 个空闲的 HY2 跳跃端口，请释放端口后重试或手动设置 HY2_HOP_PORTS"
  exit 1
}

validate_config() {
  validate_true_false "ENABLE_HY2" "$ENABLE_HY2"
  validate_true_false "ENABLE_VLESS" "$ENABLE_VLESS"
  validate_true_false "ENABLE_ANYTLS" "$ENABLE_ANYTLS"
  validate_true_false "ENABLE_SS" "$ENABLE_SS"
  validate_true_false "ENABLE_TUIC" "$ENABLE_TUIC"
  validate_true_false "ENABLE_REALITY" "$ENABLE_REALITY"
  validate_true_false "ENABLE_WS" "$ENABLE_WS"
  if [[ "$DEPLOY_MODE" != "direct" && "$DEPLOY_MODE" != "tunnel" ]]; then
    err "DEPLOY_MODE 必须是 direct 或 tunnel，当前值: $DEPLOY_MODE"
    exit 1
  fi
  if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
    [[ "$ENABLE_WS" == "true" ]] || { err "隧道模式必须启用 ENABLE_WS"; exit 1; }
    [[ "$ENABLE_HY2" != "true" && "$ENABLE_VLESS" != "true" && "$ENABLE_ANYTLS" != "true" &&
       "$ENABLE_SS" != "true" && "$ENABLE_TUIC" != "true" && "$ENABLE_REALITY" != "true" ]] || {
      err "隧道模式只支持 VLESS-WS；其它协议无法穿过 Cloudflare Tunnel，请关闭"
      exit 1
    }
    [[ -n "$CF_TUNNEL_TOKEN" ]] || { err "隧道模式必须填写 CF_TUNNEL_TOKEN"; exit 1; }
    validate_token_value "CF_TUNNEL_TOKEN" "$CF_TUNNEL_TOKEN"
    [[ -n "$WS_HOST" ]] || { err "隧道模式必须填写 WS_HOST（隧道公网域名）"; exit 1; }
    case "$CF_TUNNEL_PROTOCOL" in
      auto|quic|http2) ;;
      *) err "CF_TUNNEL_PROTOCOL 必须是 auto、quic 或 http2"; exit 1 ;;
    esac
    validate_env_value "CLOUDFLARED_IMAGE" "$CLOUDFLARED_IMAGE"
  fi
  if [[ "$ENABLE_WS" == "true" ]]; then
    validate_port "WS_PORT" "$WS_PORT"
    if [[ -n "$WS_PATH" ]]; then
      [[ "$WS_PATH" =~ ^/[A-Za-z0-9._~/-]*$ && ${#WS_PATH} -le 128 ]] || {
        err "WS_PATH 必须以 / 开头，只能包含字母、数字及 . _ ~ / -（最长 128）"
        exit 1
      }
    fi
    [[ -z "$WS_HOST" || "$WS_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { err "WS_HOST 必须是域名: $WS_HOST"; exit 1; }
    [[ -z "$WS_ADDRESS" || "$WS_ADDRESS" =~ ^[A-Za-z0-9.:-]+$ ]] || { err "WS_ADDRESS 必须是域名或 IP: $WS_ADDRESS"; exit 1; }
  fi
  validate_true_false "HY2_PORT_HOPPING" "$HY2_PORT_HOPPING"
  validate_true_false "AUTO_DOMAIN" "$AUTO_DOMAIN"
  validate_bool "$AUTO_TLS"
  if [[ "$ENABLE_HY2" == "true" ]]; then
    validate_port "HY2_PORT" "$HY2_PORT"
  fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    validate_port "VLESS_PORT" "$VLESS_PORT"
  fi
  if [[ "$ENABLE_ANYTLS" == "true" ]]; then
    validate_port "ANYTLS_PORT" "$ANYTLS_PORT"
  fi
  if [[ "$ENABLE_SS" == "true" ]]; then
    validate_port "SS_PORT" "$SS_PORT"
  fi
  if [[ "$ENABLE_TUIC" == "true" ]]; then
    validate_port "TUIC_PORT" "$TUIC_PORT"
  fi
  if [[ "$ENABLE_REALITY" == "true" ]]; then
    validate_port "REALITY_PORT" "$REALITY_PORT"
    [[ "$REALITY_SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { err "REALITY_SNI 必须是域名: $REALITY_SNI"; exit 1; }
    [[ -z "$REALITY_SHORT_ID" || "$REALITY_SHORT_ID" =~ ^([0-9a-f]{2}){1,8}$ ]] || { err "REALITY_SHORT_ID 必须是 2-16 位小写十六进制（偶数位）"; exit 1; }
  fi
  if [[ "$WARP_SCOPE" != "all" && "$WARP_SCOPE" != "split" ]]; then
    err "WARP_SCOPE 必须是 all 或 split"
    exit 1
  fi
  if [[ "$WARP_SCOPE" == "split" ]]; then
    [[ -n "$WARP_SPLIT_GEOSITE" || -n "$WARP_SPLIT_DOMAINS" ]] || { err "WARP_SCOPE=split 时 WARP_SPLIT_GEOSITE 和 WARP_SPLIT_DOMAINS 不能都为空"; exit 1; }
    [[ "$WARP_SPLIT_GEOSITE" =~ ^[a-z0-9@!._,-]*$ ]] || { err "WARP_SPLIT_GEOSITE 只能是逗号分隔的 geosite 名称"; exit 1; }
    [[ "$WARP_SPLIT_DOMAINS" =~ ^[A-Za-z0-9.,-]*$ ]] || { err "WARP_SPLIT_DOMAINS 只能是逗号分隔的域名"; exit 1; }
  fi
  validate_port "MIXED_PORT" "$MIXED_PORT"
  select_hy2_hop_ports
  validate_hy2_hop_ports
  validate_positive_int "TLS_ISSUE_RETRIES" "$TLS_ISSUE_RETRIES"
  validate_positive_int "TLS_RENEW_INTERVAL" "$TLS_RENEW_INTERVAL"
  validate_positive_int "CITY_LOOKUP_RETRIES" "$CITY_LOOKUP_RETRIES"
  validate_positive_int "CITY_LOOKUP_TIMEOUT" "$CITY_LOOKUP_TIMEOUT"
  validate_positive_int "CITY_LOOKUP_RETRY_DELAY" "$CITY_LOOKUP_RETRY_DELAY"
  validate_positive_int "WARP_PROBE_INTERVAL" "$WARP_PROBE_INTERVAL"
  if [[ "$WARP_MODE" != "auto" && "$WARP_MODE" != "usque" && "$WARP_MODE" != "wireguard" && "$WARP_MODE" != "direct" ]]; then
    err "WARP_MODE 必须是 auto、usque、wireguard 或 direct"
    exit 1
  fi
  if [[ "$USQUE_HTTP2" != "true" && "$USQUE_HTTP2" != "false" ]]; then
    err "USQUE_HTTP2 必须是 true 或 false"
    exit 1
  fi
  if [[ "$WARP_AUTORECOVER" != "true" && "$WARP_AUTORECOVER" != "false" ]]; then
    err "WARP_AUTORECOVER 必须是 true 或 false"
    exit 1
  fi
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
  validate_secret_value "ANYTLS_PASSWORD" "$ANYTLS_PASSWORD"
  validate_secret_value "SS_PASSWORD" "$SS_PASSWORD"
  validate_secret_value "TUIC_PASSWORD" "$TUIC_PASSWORD"
  validate_env_value "WARP_LICENSE_KEY" "$WARP_LICENSE_KEY"
  if [[ "$AUTO_TLS" == "true" || -n "$CF_Token" ]]; then
    validate_token_value "CF_Token" "$CF_Token"
  fi
  validate_env_value "CF_Account_ID" "$CF_Account_ID"
  validate_env_value "CF_Zone_ID" "$CF_Zone_ID"
  if [[ "$ENABLE_HY2" != "true" && "$ENABLE_VLESS" != "true" &&
        "$ENABLE_ANYTLS" != "true" && "$ENABLE_SS" != "true" &&
        "$ENABLE_TUIC" != "true" && "$ENABLE_REALITY" != "true" &&
        "$ENABLE_WS" != "true" ]]; then
    err "至少要启用一种协议 (ENABLE_HY2/ENABLE_VLESS/ENABLE_ANYTLS/ENABLE_SS/ENABLE_TUIC/ENABLE_REALITY/ENABLE_WS)"
    exit 1
  fi
  if [[ "$ENABLE_VLESS" == "true" || "$ENABLE_REALITY" == "true" || "$ENABLE_TUIC" == "true" || "$ENABLE_WS" == "true" ]]; then
    local effective_vless_uuid="${VLESS_UUID:-$AUTH_UUID}"
    if [[ -n "$effective_vless_uuid" ]] &&
       ! [[ "$effective_vless_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      err "VLESS_UUID/AUTH_UUID 不是有效的 UUID"
      exit 1
    fi
  fi
  local -a enabled_ports=()
  [[ "$ENABLE_HY2" == "true" ]] && enabled_ports+=("HY2:$HY2_PORT")
  [[ "$ENABLE_VLESS" == "true" ]] && enabled_ports+=("VLESS:$VLESS_PORT")
  [[ "$ENABLE_ANYTLS" == "true" ]] && enabled_ports+=("AnyTLS:$ANYTLS_PORT")
  [[ "$ENABLE_SS" == "true" ]] && enabled_ports+=("Shadowsocks:$SS_PORT")
  [[ "$ENABLE_TUIC" == "true" ]] && enabled_ports+=("TUIC:$TUIC_PORT")
  [[ "$ENABLE_REALITY" == "true" ]] && enabled_ports+=("Reality:$REALITY_PORT")
  [[ "$ENABLE_WS" == "true" ]] && enabled_ports+=("WS:$WS_PORT")
  enabled_ports+=("Mixed:$MIXED_PORT")
  local port_item port_value seen_ports=""
  for port_item in "${enabled_ports[@]}"; do
    port_value="${port_item#*:}"
    [[ " $seen_ports " != *" $port_value "* ]] || {
      err "启用协议端口不能重复: $port_value"
      exit 1
    }
    seen_ports="$seen_ports $port_value"
  done

  if [[ "$ENABLE_HY2" != "true" && "$ENABLE_VLESS" != "true" &&
        "$ENABLE_ANYTLS" != "true" && "$ENABLE_TUIC" != "true" ]]; then
    : # 没有需要证书的入站（隧道 / Reality / SS），跳过证书检查
  elif [[ "$AUTO_TLS" == "true" ]]; then
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

write_tunnel_compose() {
  cat >"$COMPOSE_FILE" <<EOF
services:
  singbox-warp:
    image: ${IMAGE}
    container_name: singbox-warp
    restart: unless-stopped
    init: true
    ports:
      - "127.0.0.1:\${MIXED_PORT:-1080}:\${MIXED_PORT:-1080}/tcp"
    volumes:
      - ./data:/var/lib/wgcf
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
      - ENABLE_HY2=false
      - ENABLE_VLESS=false
      - ENABLE_ANYTLS=false
      - ENABLE_SS=false
      - ENABLE_TUIC=false
      - ENABLE_REALITY=false
      - ENABLE_WS=true
      - WS_PORT=\${WS_PORT:-8080}
      - WS_PATH=\${WS_PATH:-}
      - WS_HOST=\${WS_HOST:-}
      - WS_ADDRESS=\${WS_ADDRESS:-}
      - AUTO_TLS=false
      - NODE_NAME=\${NODE_NAME:-}
      - AUTH_UUID=\${AUTH_UUID:-}
      - VLESS_UUID=\${VLESS_UUID:-}
      - MIXED_PORT=\${MIXED_PORT:-1080}
      - WARP_LICENSE_KEY=\${WARP_LICENSE_KEY:-}
      - WARP_MODE=\${WARP_MODE:-auto}
      - WARP_SCOPE=\${WARP_SCOPE:-all}
      - WARP_SPLIT_GEOSITE=\${WARP_SPLIT_GEOSITE-openai,anthropic,google-gemini,netflix,disney}
      - WARP_SPLIT_DOMAINS=\${WARP_SPLIT_DOMAINS:-}
      - WARP_AUTORECOVER=\${WARP_AUTORECOVER:-true}
      - WARP_PROBE_INTERVAL=\${WARP_PROBE_INTERVAL:-60}
      - USQUE_HTTP2=\${USQUE_HTTP2:-true}

  cloudflared:
    image: ${CLOUDFLARED_IMAGE}
    container_name: singbox-warp-cloudflared
    restart: unless-stopped
    command: ["tunnel", "--no-autoupdate", "run"]
    environment:
      - TUNNEL_TOKEN=\${CF_TUNNEL_TOKEN:?CF_TUNNEL_TOKEN is required}
      - TUNNEL_TRANSPORT_PROTOCOL=\${CF_TUNNEL_PROTOCOL:-auto}
    depends_on:
      singbox-warp:
        condition: service_started
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

write_compose() {
  if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
    write_tunnel_compose
    return 0
  fi
  local ports_block=""
  if [[ "$ENABLE_HY2" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${HY2_PORT:-32443}:\${HY2_PORT:-32443}/tcp\"
      - \"\${HY2_PORT:-32443}:\${HY2_PORT:-32443}/udp\""
    if [[ "$HY2_PORT_HOPPING" == "true" ]]; then
      local hop_start="${HY2_HOP_PORTS%-*}" hop_end="${HY2_HOP_PORTS#*-}" hop_port
      for ((hop_port=hop_start; hop_port<=hop_end; hop_port++)); do
        ports_block="${ports_block}
      - \"${hop_port}:\${HY2_PORT:-32443}/udp\""
      done
    fi
  fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${VLESS_PORT:-38443}:\${VLESS_PORT:-38443}/tcp\""
  fi
  if [[ "$ENABLE_ANYTLS" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${ANYTLS_PORT:-4443}:\${ANYTLS_PORT:-4443}/tcp\""
  fi
  if [[ "$ENABLE_SS" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${SS_PORT:-48443}:\${SS_PORT:-48443}/tcp\""
  fi
  if [[ "$ENABLE_TUIC" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${TUIC_PORT:-36443}:\${TUIC_PORT:-36443}/udp\""
  fi
  if [[ "$ENABLE_REALITY" == "true" ]]; then
    ports_block="${ports_block}
      - \"\${REALITY_PORT:-443}:\${REALITY_PORT:-443}/tcp\""
  fi
  ports_block="${ports_block}
      - \"127.0.0.1:\${MIXED_PORT:-1080}:\${MIXED_PORT:-1080}/tcp\""

  cat >"$COMPOSE_FILE" <<EOF
services:
  singbox-warp:
    image: ${IMAGE}
    container_name: singbox-warp
    restart: unless-stopped
    init: true
    ports:
${ports_block}
    volumes:
      - ./data:/var/lib/wgcf
      - ./certs:/etc/sing-box/certs
      - ./acme:/var/lib/acme
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
      - HY2_PORT_HOPPING=\${HY2_PORT_HOPPING:-false}
      - HY2_HOP_PORTS=\${HY2_HOP_PORTS:-}
      - VLESS_PORT=\${VLESS_PORT:-38443}
      - ANYTLS_PORT=\${ANYTLS_PORT:-4443}
      - SS_PORT=\${SS_PORT:-48443}
      - MIXED_PORT=\${MIXED_PORT:-1080}
      - ENABLE_HY2=\${ENABLE_HY2:-true}
      - ENABLE_VLESS=\${ENABLE_VLESS:-true}
      - ENABLE_ANYTLS=\${ENABLE_ANYTLS:-false}
      - ENABLE_SS=\${ENABLE_SS:-false}
      - TUIC_PORT=\${TUIC_PORT:-36443}
      - ENABLE_TUIC=\${ENABLE_TUIC:-false}
      - TUIC_PASSWORD=\${TUIC_PASSWORD:-}
      - REALITY_PORT=\${REALITY_PORT:-443}
      - ENABLE_REALITY=\${ENABLE_REALITY:-false}
      - REALITY_SNI=\${REALITY_SNI:-www.microsoft.com}
      - REALITY_SHORT_ID=\${REALITY_SHORT_ID:-}
      - ENABLE_WS=\${ENABLE_WS:-false}
      - WS_PORT=\${WS_PORT:-8080}
      - WS_PATH=\${WS_PATH:-}
      - WS_HOST=\${WS_HOST:-}
      - WS_ADDRESS=\${WS_ADDRESS:-}
      - WARP_SCOPE=\${WARP_SCOPE:-all}
      - WARP_SPLIT_GEOSITE=\${WARP_SPLIT_GEOSITE-openai,anthropic,google-gemini,netflix,disney}
      - WARP_SPLIT_DOMAINS=\${WARP_SPLIT_DOMAINS:-}
      - AUTH_UUID=\${AUTH_UUID:-}
      - HY2_PASSWORD=\${HY2_PASSWORD:-}
      - VLESS_UUID=\${VLESS_UUID:-}
      - ANYTLS_PASSWORD=\${ANYTLS_PASSWORD:-}
      - SS_PASSWORD=\${SS_PASSWORD:-}
      - AUTO_TLS=\${AUTO_TLS:-false}
      - TLS_DOMAIN=\${TLS_DOMAIN:-}
      - NODE_NAME=\${NODE_NAME:-}
      - TLS_CERT_PATH=\${TLS_CERT_PATH:-/etc/sing-box/certs/fullchain.pem}
      - TLS_KEY_PATH=\${TLS_KEY_PATH:-/etc/sing-box/certs/privkey.pem}
      - ACME_EMAIL=\${ACME_EMAIL:-}
      - TLS_ISSUE_RETRIES=\${TLS_ISSUE_RETRIES:-3}
      - TLS_RENEW_INTERVAL=\${TLS_RENEW_INTERVAL:-43200}
      - WARP_LICENSE_KEY=\${WARP_LICENSE_KEY:-}
      - WARP_MODE=\${WARP_MODE:-auto}
      - WARP_AUTORECOVER=\${WARP_AUTORECOVER:-true}
      - WARP_PROBE_INTERVAL=\${WARP_PROBE_INTERVAL:-60}
      - USQUE_HTTP2=\${USQUE_HTTP2:-true}
      - CF_Token=\${CF_Token:-}
      - CF_Account_ID=\${CF_Account_ID:-}
      - CF_Zone_ID=\${CF_Zone_ID:-}
EOF
}

write_env() {
  cat >"$ENV_FILE" <<EOF
HY2_PORT=$HY2_PORT
HY2_PORT_HOPPING=$HY2_PORT_HOPPING
HY2_HOP_PORTS=$HY2_HOP_PORTS
VLESS_PORT=$VLESS_PORT
ANYTLS_PORT=$ANYTLS_PORT
SS_PORT=$SS_PORT
MIXED_PORT=$MIXED_PORT
ENABLE_HY2=$ENABLE_HY2
ENABLE_VLESS=$ENABLE_VLESS
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_SS=$ENABLE_SS
TUIC_PORT=$TUIC_PORT
ENABLE_TUIC=$ENABLE_TUIC
TUIC_PASSWORD=$TUIC_PASSWORD
REALITY_PORT=$REALITY_PORT
ENABLE_REALITY=$ENABLE_REALITY
REALITY_SNI=$REALITY_SNI
REALITY_SHORT_ID=$REALITY_SHORT_ID
DEPLOY_MODE=$DEPLOY_MODE
ENABLE_WS=$ENABLE_WS
WS_PORT=$WS_PORT
WS_PATH=$WS_PATH
WS_HOST=$WS_HOST
WS_ADDRESS=$WS_ADDRESS
CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN
CF_TUNNEL_PROTOCOL=$CF_TUNNEL_PROTOCOL
CLOUDFLARED_IMAGE=$CLOUDFLARED_IMAGE
WARP_SCOPE=$WARP_SCOPE
WARP_SPLIT_GEOSITE=$WARP_SPLIT_GEOSITE
WARP_SPLIT_DOMAINS=$WARP_SPLIT_DOMAINS
AUTO_DOMAIN=$AUTO_DOMAIN
BASE_DOMAIN=$BASE_DOMAIN
NODE_NAME=$NODE_NAME
AUTH_UUID=$AUTH_UUID
HY2_PASSWORD=$HY2_PASSWORD
VLESS_UUID=$VLESS_UUID
ANYTLS_PASSWORD=$ANYTLS_PASSWORD
SS_PASSWORD=$SS_PASSWORD
AUTO_TLS=$AUTO_TLS
TLS_DOMAIN=$TLS_DOMAIN
TLS_CERT_PATH=$TLS_CERT_PATH
TLS_KEY_PATH=$TLS_KEY_PATH
ACME_EMAIL=$ACME_EMAIL
TLS_ISSUE_RETRIES=$TLS_ISSUE_RETRIES
TLS_RENEW_INTERVAL=$TLS_RENEW_INTERVAL
WARP_LICENSE_KEY=$WARP_LICENSE_KEY
WARP_MODE=$WARP_MODE
WARP_AUTORECOVER=$WARP_AUTORECOVER
WARP_PROBE_INTERVAL=$WARP_PROBE_INTERVAL
USQUE_HTTP2=$USQUE_HTTP2
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

create_backup_archive() {
  local archive="$1"
  local items=()
  local item
  for item in "$ENV_FILE_NAME" "$COMPOSE_FILE_NAME" data certs acme "$STATE_DIR_NAME"; do
    [[ -e "$APP_DIR/$item" ]] && items+=("$item")
  done
  [[ "${#items[@]}" -gt 0 ]] || {
    err "部署目录中没有可备份的数据"
    return 1
  }
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$APP_DIR" "${items[@]}"
  chmod 600 "$archive"
}

validate_backup_archive() {
  local archive="$1"
  local entry
  tar -tzf "$archive" >/dev/null 2>&1 || {
    err "备份归档损坏或格式不受支持: $archive"
    return 1
  }
  if ! tar -tvzf "$archive" | awk 'substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { exit 1 }'; then
    err "备份包含符号链接或硬链接，拒绝恢复"
    return 1
  fi
  while IFS= read -r entry; do
    entry="${entry#./}"
    case "$entry" in
      ""|..|../*|*/..|*/../*|/*)
        err "备份包含不安全路径: $entry"
        return 1
        ;;
    esac
    case "$entry" in
      "$ENV_FILE_NAME"|"$COMPOSE_FILE_NAME"|data|data/*|certs|certs/*|acme|acme/*|"$STATE_DIR_NAME"|"$STATE_DIR_NAME"/*) ;;
      *)
        err "备份包含不允许的路径: $entry"
        return 1
        ;;
    esac
  done < <(tar -tzf "$archive")
}

cmd_backup() {
  need_cmd tar
  [[ -d "$APP_DIR" ]] || { err "部署目录不存在: $APP_DIR"; return 1; }
  local archive was_running="false"
  archive="$BACKUP_DIR/singbox-warp-$(date +%Y%m%d-%H%M%S).tar.gz"
  if command -v docker >/dev/null 2>&1 && docker inspect singbox-warp --format '{{.State.Running}}' 2>/dev/null | grep -Fxq true; then
    was_running="true"
    docker stop singbox-warp >/dev/null
  fi
  local backup_ok="false"
  if create_backup_archive "$archive"; then
    backup_ok="true"
  fi
  if [[ "$was_running" == "true" ]]; then
    docker start singbox-warp >/dev/null || err "重启容器失败，请手动检查"
  fi
  if [[ "$backup_ok" != "true" ]]; then
    return 1
  fi
  if [[ "$was_running" == "true" ]]; then
    wait_healthy || return 1
  fi
  log "备份完成: $archive"
}

cmd_restore() {
  need_cmd tar
  need_cmd docker
  local latest="" archive pre_restore
  if [[ -d "$BACKUP_DIR" ]]; then
    latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'singbox-warp-*.tar.gz' | sort | tail -n1)"
  fi
  archive="$(ask_input "备份文件路径" "$latest")"
  [[ -f "$archive" ]] || { err "备份文件不存在: $archive"; return 1; }
  validate_backup_archive "$archive" || return 1
  if [[ "$(normalize_bool "$(ask_choice "恢复会覆盖当前配置并重启服务，继续 (y/n)" "n")")" != "true" ]]; then
    log "已取消恢复"
    return 0
  fi

  pre_restore="$(mktemp --suffix=.tar.gz)"
  if [[ -f "$COMPOSE_FILE" ]]; then
    if ! (cd "$APP_DIR" && docker compose down); then
      err "停止现有容器失败，已中止恢复"
      return 1
    fi
  fi
  if ! create_backup_archive "$pre_restore"; then
    rm -f "$pre_restore"
    err "无法创建恢复前备份，已中止"
    (cd "$APP_DIR" && docker compose up -d) || true
    return 1
  fi
  if ! tar -xzf "$archive" -C "$APP_DIR"; then
    err "恢复归档失败，正在还原原配置"
    tar -xzf "$pre_restore" -C "$APP_DIR" || true
    rm -f "$pre_restore"
    (cd "$APP_DIR" && docker compose up -d) || true
    return 1
  fi
  chmod 600 "$ENV_FILE"
  if ! (cd "$APP_DIR" && docker compose up -d) || ! wait_healthy; then
    err "恢复后的服务不健康，正在回退"
    (cd "$APP_DIR" && docker compose down) || true
    tar -xzf "$pre_restore" -C "$APP_DIR" || true
    (cd "$APP_DIR" && docker compose up -d) || true
    wait_healthy || true
    rm -f "$pre_restore"
    return 1
  fi
  rm -f "$pre_restore"
  log "备份恢复完成: $archive"
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
  return 1
}

# 隧道模式：容器健康只说明 sing-box 在跑，还要确认 cloudflared 连上了 Cloudflare。
# 连不上通常是 token 错误或 UDP 7844 被封，只给出提示，不回滚配置。
check_tunnel_connected() {
  TUNNEL_FAILED=false
  [[ "$DEPLOY_MODE" == "tunnel" ]] || return 0
  local i
  for i in $(seq 1 20); do
    if docker logs --tail 200 singbox-warp-cloudflared 2>&1 | grep -q 'Registered tunnel connection'; then
      log "隧道已连接到 Cloudflare"
      probe_tunnel_hostname
      return 0
    fi
    if ! docker inspect singbox-warp-cloudflared --format '{{.State.Running}}' 2>/dev/null | grep -Fxq true &&
       (( i > 3 )); then
      break
    fi
    sleep 3
  done
  local cf_logs
  cf_logs="$(docker logs --tail 200 singbox-warp-cloudflared 2>&1 || true)"
  TUNNEL_FAILED=true
  if grep -Eq 'Failed to get tunnel|Unauthorized|invalid token|not valid|Provided Tunnel token is not valid' <<<"$cf_logs"; then
    err "隧道没连上：Cloudflare 不认这个 token（token 复制错了，或这个隧道已被删除）"
  elif grep -Eq '7844|quic.*(timeout|failed)|no recent network activity' <<<"$cf_logs"; then
    err "隧道没连上：连不到 Cloudflare 的 7844 端口；把 CF_TUNNEL_PROTOCOL 改为 http2 再试"
  else
    err "cloudflared 未能连接到 Cloudflare；请检查 CF_TUNNEL_TOKEN，UDP 7844 不通时把 CF_TUNNEL_PROTOCOL 改为 http2"
  fi
  printf "cloudflared 最近日志:\n" >&2
  grep -E ' ERR ' <<<"$cf_logs" | sed 's/.* ERR /  ERR /' | sort -u | tail -n 5 >&2 || true
  guide_line "  token 填错的话，到这里重新复制: $GUIDE_CF_TUNNELS_URL" \
    "  改 token 或协议: 菜单选「修改配置」"
  return 0
}

cmd_status() {
  need_cmd docker
  [[ -f "$ENV_FILE" ]] && load_existing_env
  docker ps --format '{{.Names}} {{.Status}} {{.Image}}' | grep '^singbox-warp ' || {
    err "singbox-warp 容器未运行"
    return 1
  }
  printf '\n状态总览\n'
  printf '  管理脚本: v%s\n' "$SCRIPT_VERSION"
  printf '  部署目录: %s\n' "$APP_DIR"
  printf '  部署模式: %s\n' "${DEPLOY_MODE:-direct}"
  if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
    printf '  隧道域名: %s\n' "${WS_HOST:-未配置}"
    printf '  cloudflared: %s\n' "$(docker inspect singbox-warp-cloudflared --format '{{.State.Status}}' 2>/dev/null || echo 未运行)"
  else
    printf '  域名: %s\n' "${TLS_DOMAIN:-未配置}"
  fi
  if [[ "$ENABLE_WS" == "true" ]]; then printf '  VLESS-WS: true (端口 %s, 仅 Docker 内网)\n' "$WS_PORT"; fi
  printf '  HY2: %s (端口 %s)\n' "$ENABLE_HY2" "$HY2_PORT"
  printf '  VLESS: %s (端口 %s)\n' "$ENABLE_VLESS" "$VLESS_PORT"
  printf '  TUIC: %s (端口 %s/udp)\n' "$ENABLE_TUIC" "$TUIC_PORT"
  printf '  Reality: %s (端口 %s)\n' "$ENABLE_REALITY" "$REALITY_PORT"
  printf '  WARP 范围: %s\n' "$WARP_SCOPE"
  printf '  Mixed: 127.0.0.1:%s\n' "$MIXED_PORT"
  docker inspect singbox-warp --format '  镜像: {{.Config.Image}}'
  docker inspect singbox-warp --format '  镜像 ID: {{.Image}}'
  docker inspect singbox-warp --format '  健康状态: {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
  printf '  sing-box: %s\n' "$(docker exec singbox-warp sing-box version 2>/dev/null | head -n1 || echo unknown)"
  printf '  wgcf: %s\n' "$(docker exec singbox-warp wgcf --version 2>/dev/null | head -n1 || echo unknown)"
  if docker exec singbox-warp test -s "$TLS_CERT_PATH" >/dev/null 2>&1; then
    printf '  证书到期: %s\n' "$(docker exec singbox-warp openssl x509 -in "$TLS_CERT_PATH" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  fi
  if command -v curl >/dev/null 2>&1; then
    printf '  WARP 出口 IP: %s\n' "$(curl -fsSL --max-time 10 --proxy "socks5h://127.0.0.1:$MIXED_PORT" https://api.ipify.org 2>/dev/null || echo unavailable)"
  fi
}

cmd_show_nodes() {
  need_cmd docker
  need_cmd jq
  if ! docker ps --format '{{.Names}}' | grep -Fxq 'singbox-warp'; then
    err "未找到 singbox-warp 容器"
    return 1
  fi
  if ! command -v qrencode >/dev/null 2>&1; then
    if [[ "$(normalize_bool "$(ask_choice "未安装 qrencode，是否安装以显示二维码 (y/n)" "y")")" == "true" ]]; then
      ensure_host_tools
    fi
  fi

  local cfg
  local hy2_password hy2_port hy2_sni hy2_tag hy2_insecure hy2_link
  local vless_uuid vless_port vless_sni vless_tag vless_flow vless_link
  local anytls_password anytls_port anytls_sni anytls_tag anytls_link
  local ss_password ss_port ss_method ss_tag ss_link ss_userinfo
  local node_name
  local has_any="false"
  node_name="$(normalize_name "${NODE_NAME:-${TLS_DOMAIN:-${WS_HOST:-node}}}")"
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
    hy2_link="hy2://${hy2_password}@${hy2_sni}:${hy2_port}?sni=${hy2_sni}&insecure=${hy2_insecure:-0}#${hy2_tag}"
    if [[ "$HY2_PORT_HOPPING" == "true" && -n "$HY2_HOP_PORTS" ]]; then
      hy2_link="hy2://${hy2_password}@${hy2_sni}:${hy2_port}?sni=${hy2_sni}&mport=${HY2_HOP_PORTS}&insecure=${hy2_insecure:-0}#${hy2_tag}"
    fi
    printf '[node] %s\n' "$hy2_link"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$hy2_link"
    fi
    has_any="true"
  fi

  vless_uuid="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.tls.reality.enabled // false) | not) and ((.transport.type // "") != "ws")) | .users[0].uuid // empty' | head -n1)"
  vless_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.tls.reality.enabled // false) | not) and ((.transport.type // "") != "ws")) | .listen_port // empty' | head -n1)"
  vless_sni="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.tls.reality.enabled // false) | not) and ((.transport.type // "") != "ws")) | .tls.server_name // empty' | head -n1)"
  vless_tag="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.tls.reality.enabled // false) | not) and ((.transport.type // "") != "ws")) | .tag // empty' | head -n1)"
  vless_flow="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.tls.reality.enabled // false) | not) and ((.transport.type // "") != "ws")) | .users[0].flow // empty' | head -n1)"
  if [[ -n "$vless_uuid" && -n "$vless_port" && -n "$vless_sni" ]]; then
    vless_tag="${vless_tag:-vless-${node_name}}"
    vless_link="vless://${vless_uuid}@${vless_sni}:${vless_port}?encryption=none&security=tls&sni=${vless_sni}&type=tcp"
    if [[ -n "$vless_flow" ]]; then
      vless_link="${vless_link}&flow=${vless_flow}"
    fi
    vless_link="${vless_link}#${vless_tag}"
    printf '[node] %s\n' "$vless_link"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$vless_link"
    fi
    has_any="true"
  fi

  anytls_password="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="anytls") | .users[0].password // empty' | head -n1)"
  anytls_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="anytls") | .listen_port // empty' | head -n1)"
  anytls_sni="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="anytls") | .tls.server_name // empty' | head -n1)"
  anytls_tag="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="anytls") | .tag // empty' | head -n1)"
  if [[ -n "$anytls_password" && -n "$anytls_port" && -n "$anytls_sni" ]]; then
    anytls_tag="${anytls_tag:-anytls-${node_name}}"
    anytls_link="anytls://${anytls_password}@${anytls_sni}:${anytls_port}/?sni=${anytls_sni}#${anytls_tag}"
    printf '[node] %s\n' "$anytls_link"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$anytls_link"
    fi
    has_any="true"
  fi

  local reality_uuid reality_port reality_sni reality_sid reality_pbk reality_link creds
  local tuic_uuid tuic_password tuic_port tuic_sni tuic_link
  creds="$(docker exec singbox-warp sh -c 'cat /var/lib/wgcf/credentials.env' 2>/dev/null || true)"
  reality_uuid="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and (.tls.reality.enabled // false)) | .users[0].uuid // empty' | head -n1)"
  reality_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and (.tls.reality.enabled // false)) | .listen_port // empty' | head -n1)"
  reality_sni="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and (.tls.reality.enabled // false)) | .tls.server_name // empty' | head -n1)"
  reality_sid="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and (.tls.reality.enabled // false)) | .tls.reality.short_id[0] // empty' | head -n1)"
  reality_pbk="$(printf '%s\n' "$creds" | sed -n 's/^REALITY_PUBLIC_KEY=//p' | head -n1)"
  if [[ -n "$reality_uuid" && -n "$reality_port" && -n "$reality_pbk" && -n "$TLS_DOMAIN" ]]; then
    reality_link="vless://${reality_uuid}@${TLS_DOMAIN}:${reality_port}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_pbk}&sid=${reality_sid}&type=tcp&flow=xtls-rprx-vision#reality-${node_name}"
    printf '[node] %s\n' "$reality_link"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$reality_link"
    fi
    has_any="true"
  fi

  tuic_uuid="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="tuic") | .users[0].uuid // empty' | head -n1)"
  tuic_password="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="tuic") | .users[0].password // empty' | head -n1)"
  tuic_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port // empty' | head -n1)"
  tuic_sni="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="tuic") | .tls.server_name // empty' | head -n1)"
  if [[ -n "$tuic_uuid" && -n "$tuic_password" && -n "$tuic_port" && -n "$tuic_sni" ]]; then
    tuic_link="tuic://${tuic_uuid}:${tuic_password}@${tuic_sni}:${tuic_port}?sni=${tuic_sni}&alpn=h3&congestion_control=bbr#tuic-${node_name}"
    printf '[node] %s\n' "$tuic_link"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$tuic_link"
    fi
    has_any="true"
  fi

  local ws_uuid ws_path ws_host ws_link
  ws_uuid="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.transport.type // "") == "ws")) | .users[0].uuid // empty' | head -n1)"
  ws_path="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="vless" and ((.transport.type // "") == "ws")) | .transport.path // empty' | head -n1)"
  ws_host="${WS_HOST:-}"
  if [[ -n "$ws_uuid" && -n "$ws_path" ]]; then
    if [[ -n "$ws_host" ]]; then
      ws_link="vless://${ws_uuid}@${WS_ADDRESS:-$ws_host}:443?encryption=none&security=tls&sni=${ws_host}&host=${ws_host}&type=ws&path=$(jq -rn --arg v "$ws_path" '$v|@uri')#ws-${node_name}"
      printf '[node] %s\n' "$ws_link"
      if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$ws_link"
      fi
      has_any="true"
    else
      diag_warn "VLESS-WS 已启用但未设置 WS_HOST，无法生成节点链接（路径 ${ws_path}）"
    fi
  fi

  ss_password="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="shadowsocks") | .password // empty' | head -n1)"
  ss_port="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="shadowsocks") | .listen_port // empty' | head -n1)"
  ss_method="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="shadowsocks") | .method // empty' | head -n1)"
  ss_tag="$(printf '%s\n' "$cfg" | jq -r '.inbounds[]? | select(.type=="shadowsocks") | .tag // empty' | head -n1)"
  if [[ -n "$ss_password" && -n "$ss_port" && -n "$ss_method" && -n "$TLS_DOMAIN" ]]; then
    ss_tag="${ss_tag:-ss-${node_name}}"
    ss_userinfo="$(printf '%s:%s' "$ss_method" "$ss_password" | base64 | tr -d '\r\n')"
    ss_link="ss://${ss_userinfo}@${TLS_DOMAIN}:${ss_port}#${ss_tag}"
    printf '[node] %s\n' "$ss_link"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$ss_link"
    fi
    has_any="true"
  fi

  if [[ "$has_any" == "true" ]]; then
    command -v qrencode >/dev/null 2>&1 || diag_warn "未安装 qrencode，本次只显示节点链接"
    return 0
  fi
  err "无法从运行配置解析节点链接；该操作不会自动修改或重启服务"
  return 1
}

apply_rollback_image() {
  local rollback_image="$1"
  [[ -f "$COMPOSE_FILE" ]] || { err "缺少 compose 文件: $COMPOSE_FILE"; return 1; }
  # 只替换第一个 image（singbox-warp 服务）；隧道模式下 cloudflared 的镜像保持不变
  sed -i -E "0,/^[[:space:]]*image:/s#^([[:space:]]*image:[[:space:]]*).+#\1${rollback_image}#" "$COMPOSE_FILE"
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
  # 先装 curl/jq，输入阶段就能在线校验 Token
  ensure_host_tools
  collect_bootstrap_inputs install
  validate_config
  confirm_config || { log "已取消安装"; return 0; }
  ensure_docker
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
  wait_healthy || {
    err "首次安装未通过健康检查，请根据上方日志修正配置后重试"
    return 1
  }
  check_tunnel_connected
  persist_active_app_dir
  if [[ "${TUNNEL_FAILED:-false}" == "true" ]]; then
    err "部署已完成，但隧道还没连上，节点暂时不能用: $APP_DIR"
  else
    log "初始化部署完成: $APP_DIR"
  fi
}

cmd_update_image() {
  need_cmd docker
  [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || {
    err "未找到现有部署，请先执行首次安装"
    return 1
  }
  if [[ -s "$UPDATE_IMAGE_FILE" ]] && grep -Eq '^[[:space:]]*image:[[:space:]]*([^[:space:]]+@sha256:|sha256:)' "$COMPOSE_FILE"; then
    sed -i -E "0,/^[[:space:]]*image:/s#^([[:space:]]*image:[[:space:]]*).+#\1$(cat "$UPDATE_IMAGE_FILE")#" "$COMPOSE_FILE"
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
  IMAGE="$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n1 | sed -E 's/^\s*image:\s*//')"
  ensure_host_tools
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
  check_tunnel_connected
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

  local need_tls="false"
  if [[ "$ENABLE_HY2" == "true" || "$ENABLE_VLESS" == "true" || "$ENABLE_ANYTLS" == "true" || "$ENABLE_TUIC" == "true" ]]; then
    need_tls="true"
  fi

  if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
    if docker inspect singbox-warp-cloudflared --format '{{.State.Running}}' 2>/dev/null | grep -Fxq true; then
      diag_ok "cloudflared 正在运行"
      if docker logs --tail 200 singbox-warp-cloudflared 2>&1 | grep -q 'Registered tunnel connection'; then
        diag_ok "隧道已连接到 Cloudflare"
      else
        diag_warn "最近日志里没有看到隧道连接成功；UDP 7844 不通时可把 CF_TUNNEL_PROTOCOL 改为 http2"
      fi
    else
      diag_fail "cloudflared 容器未运行"
    fi
    if [[ -n "$WS_HOST" ]]; then
      diag_ok "隧道域名: $WS_HOST"
      probe_tunnel_hostname
    else
      diag_fail "WS_HOST 为空，无法生成节点链接"
    fi
  fi

  if [[ "$need_tls" != "true" ]]; then
    diag_ok "没有需要证书的入站，跳过域名和证书检查"
  elif [[ -n "$TLS_DOMAIN" ]]; then
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
  elif [[ "$need_tls" == "true" ]]; then
    diag_warn "未检查 Cloudflare Token（Token、curl 或 jq 缺失）"
  fi

  if [[ "$need_tls" != "true" ]]; then
    :
  elif docker exec singbox-warp test -s "$TLS_CERT_PATH" >/dev/null 2>&1; then
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

disable_auto_update() {
  if command -v systemctl >/dev/null 2>&1; then
    run_root systemctl disable --now singbox-warp-update.timer >/dev/null 2>&1 || true
  fi
}

cmd_auto_update_settings() {
  command -v systemctl >/dev/null 2>&1 || { err "当前系统不支持 systemd"; return 1; }
  printf '\n自动更新设置\n  1) 启用（每天检查）\n  2) 禁用\n  3) 查看状态\n'
  local choice
  choice="$(ask_input "请选择 [1-3]" "3")"
  case "$choice" in
    1)
      if ! cmd_update_script; then
        err "管理脚本更新失败，已取消启用自动更新"
        return 1
      fi
      cat <<'EOF' | run_root tee /etc/systemd/system/singbox-warp-update.service >/dev/null
[Unit]
Description=Update singbox-warp image with health-check rollback
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/flock -n -E 0 /run/singbox-warp-update.lock /usr/local/bin/swd auto-update
EOF
      cat <<'EOF' | run_root tee /etc/systemd/system/singbox-warp-update.timer >/dev/null
[Unit]
Description=Daily singbox-warp update check

[Timer]
OnCalendar=*-*-* 04:15:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
      run_root systemctl daemon-reload
      run_root systemctl enable --now singbox-warp-update.timer
      log "自动更新已启用；更新失败时会自动回滚镜像"
      ;;
    2)
      disable_auto_update
      log "自动更新已禁用"
      ;;
    3)
      systemctl status singbox-warp-update.timer --no-pager || true
      ;;
    *)
      err "无效选择: $choice"
      return 1
      ;;
  esac
}

cmd_auto_update() {
  cmd_update_script || err "管理脚本自动更新失败，继续检查镜像"
  cmd_update_image
}

validate_uninstall_dir() {
  [[ "$APP_DIR" == /* && -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]] || return 1
  [[ "$(readlink -f "$APP_DIR")" == "$APP_DIR" ]] || return 1
  case "$APP_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var) return 1 ;;
  esac
}

cmd_uninstall() {
  need_cmd docker
  printf '\n卸载服务\n  1) 删除容器，保留配置和数据\n  2) 完全卸载并删除部署目录\n  3) 取消\n'
  local choice confirm final_backup
  choice="$(ask_input "请选择 [1-3]" "3")"
  case "$choice" in
    1)
      if [[ "$(normalize_bool "$(ask_choice "确认停止并删除容器 (y/n)" "n")")" != "true" ]]; then return 0; fi
      disable_auto_update
      (cd "$APP_DIR" && docker compose down)
      log "容器已删除，配置和持久化数据保留在 $APP_DIR"
      ;;
    2)
      validate_uninstall_dir || { err "拒绝删除不安全或无效的部署目录: $APP_DIR"; return 1; }
      confirm="$(ask_input "此操作不可撤销，请输入 DELETE 确认" "")"
      [[ "$confirm" == "DELETE" ]] || { log "已取消卸载"; return 0; }
      need_cmd tar
      final_backup="$(dirname "$APP_DIR")/singbox-warp-final-$(date +%Y%m%d-%H%M%S).tar.gz"
      (cd "$APP_DIR" && docker compose stop) || true
      if ! create_backup_archive "$final_backup"; then
        (cd "$APP_DIR" && docker compose up -d) || true
        err "最终备份失败，已中止卸载"
        return 1
      fi
      disable_auto_update
      (cd "$APP_DIR" && docker compose down) || true
      run_root rm -rf -- "$APP_DIR"
      if [[ -f "$ACTIVE_INSTANCE_FILE" ]] && [[ "$(head -n1 "$ACTIVE_INSTANCE_FILE")" == "$APP_DIR" ]]; then
        run_root rm -f "$ACTIVE_INSTANCE_FILE"
      fi
      run_root rm -f /etc/systemd/system/singbox-warp-update.service /etc/systemd/system/singbox-warp-update.timer /usr/local/bin/swd
      run_root systemctl daemon-reload >/dev/null 2>&1 || true
      log "完全卸载完成；最终备份: $final_backup"
      ;;
    3) log "已取消卸载" ;;
    *) err "无效选择: $choice"; return 1 ;;
  esac
}

cmd_logs() {
  need_cmd docker
  docker logs --tail 100 -f singbox-warp || true
}

cmd_restart() {
  need_cmd docker
  if ! docker restart singbox-warp >/dev/null; then
    err "重启 singbox-warp 容器失败"
    return 1
  fi
  wait_healthy || return 1
  log "服务重启完成"
}

main() {
  if [[ "${1:-}" == "-v" || "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
    printf 'singbox-warp manager v%s\n' "$SCRIPT_VERSION"
    return 0
  fi
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
    usage
    return 0
  fi
  if [[ "${1:-}" == "guide" ]]; then
    cmd_guide
    return 0
  fi
  if [[ -n "${1:-}" && "${1:-}" != "auto-update" ]]; then
    err "此脚本仅支持交互模式，请不要带参数直接运行"
    usage
    exit 1
  fi
  ensure_root "$@"
  load_active_app_dir
  self_install_swd
  if [[ "${1:-}" == "auto-update" ]]; then
    cmd_auto_update
    return 0
  fi
  while true; do
    action="$(ask_menu_choice)"
    case "$action" in
      1) cmd_bootstrap || true ;;
      2) cmd_update_image || true ;;
      3) cmd_update_script || true ;;
      4) cmd_edit_config || true ;;
      5) cmd_show_nodes || true ;;
      6) cmd_status || true ;;
      7) cmd_diagnose || true ;;
      8) cmd_logs ;;
      9) cmd_restart || true ;;
      10) cmd_backup || true ;;
      11) cmd_restore || true ;;
      12) cmd_auto_update_settings || true ;;
      13) cmd_rollback || true ;;
      14) cmd_uninstall || true ;;
      15) cmd_guide ;;
      16) log "退出"; return 0 ;;
    esac
  done
}

main "$@"
