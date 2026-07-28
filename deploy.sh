#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.2.0"
SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/caichengle666/singbox-warp-docker/main/deploy.sh}"

# ── 颜色系统 ──────────────────────────────────────────────
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
fi

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

log()  { printf '%s[deploy]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[  OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[ WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

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

print_banner() {
  printf '\n'
  printf '%s' "$C_BOLD"
  printf '  ╔══════════════════════════════════════════╗\n'
  printf '  ║   singbox-warp-docker  部署管理工具      ║\n'
  printf '  ║   v%s                               ║\n' "$SCRIPT_VERSION"
  printf '  ╚══════════════════════════════════════════╝\n'
  printf '%s' "$C_RESET"
  printf '\n'
}

usage() {
  cat <<'EOF'
Usage:
  deploy.sh

Environment:
  APP_DIR         部署目录 (default: /opt/singbox-warp)
  IMAGE           Runtime image (default: ghcr.io/caichengle666/singbox-warp-docker:latest)
  SCRIPT_UPDATE_URL  脚本自更新地址 (default: GitHub main deploy.sh)

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

docker_cmd() {
  if is_root; then
    printf 'docker'
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    printf 'docker'
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    printf 'sudo -i docker'
    return 0
  fi
  err "当前用户无法访问 Docker，请使用免密 sudo 或将用户加入 docker 组"
  return 1
}

dc() {
  local cmd
  cmd="$(docker_cmd)" || return 1
  $cmd "$@"
}

dcc() {
  if is_root; then
    (cd "$APP_DIR" && docker "$@")
    return
  fi
  if docker info >/dev/null 2>&1; then
    (cd "$APP_DIR" && docker "$@")
    return
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    local app_dir_q
    printf -v app_dir_q '%q' "$APP_DIR"
    sudo -i bash -lc "cd $app_dir_q && docker $*"
    return
  fi
  err "当前用户无法访问 Docker，请使用免密 sudo 或将用户加入 docker 组"
  return 1
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

is_deployed() {
  [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]]
}

container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  dc inspect singbox-warp --format '{{.State.Running}}' 2>/dev/null | grep -q '^true$'
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

read_line() {
  local __result_var="$1"
  local __value=""
  if [[ "${FORCE_STDIN:-0}" == "1" ]]; then
    if ! read -r __value; then
      err "未能从 stdin 读取交互输入"
      exit 1
    fi
  elif [[ -r /dev/tty ]]; then
    if ! read -r __value < /dev/tty; then
      err "未能从终端读取交互输入"
      exit 1
    fi
  else
    if ! read -r __value; then
      err "未检测到交互终端；请使用: curl ... -o deploy.sh && bash deploy.sh"
      exit 1
    fi
  fi
  printf -v "$__result_var" '%s' "$__value"
}

ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "$default" ]]; then
    printf "%s%s%s [%s]: " "$C_CYAN" "$prompt" "$C_RESET" "$default" >&2
  else
    printf "%s%s%s: " "$C_CYAN" "$prompt" "$C_RESET" >&2
  fi
  read_line value
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  printf '%s' "$value"
}

ask_port() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    value="$(ask_input "$prompt" "$default")"
    if [[ "$value" =~ ^[1-9][0-9]*$ ]] && (( 10#$value <= 65535 )); then
      printf '%s' "$value"
      return 0
    fi
    err "端口必须是 1-65535 的正整数，当前值: $value"
  done
}

ask_choice() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    printf "%s%s%s [%s]: " "$C_CYAN" "$prompt" "$C_RESET" "$default" >&2
    read_line value
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
    printf "%s%s%s [已配置，留空保持不变]: " "$C_CYAN" "$prompt" "$C_RESET" >&2
  else
    printf "%s%s%s: " "$C_CYAN" "$prompt" "$C_RESET" >&2
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
  local deployed="$1"
  local value=""
  while true; do
    printf '\n' >&2
    if [[ "$deployed" == "true" ]]; then
      printf '%s  当前部署: %s%s\n' "$C_DIM" "$APP_DIR" "$C_RESET" >&2
    else
      printf '%s  尚未部署%s\n' "$C_DIM" "$C_RESET" >&2
    fi
    printf '\n' >&2
    printf "  1) 首次安装\n" >&2
    if [[ "$deployed" == "true" ]]; then
      printf "  2) 更新镜像\n" >&2
      printf "  3) 修改配置\n" >&2
      printf "  4) 查看节点\n" >&2
      printf "  5) 查看状态\n" >&2
      printf "  6) 诊断检查\n" >&2
      printf "  7) 查看日志\n" >&2
      printf "  8) 重启服务\n" >&2
      printf "  9) 回滚镜像\n" >&2
      printf " 10) %s卸载%s\n" "$C_RED" "$C_RESET" >&2
    fi
    printf " 11) 更新脚本\n" >&2
    printf "  0) 退出\n" >&2
    printf '\n' >&2
    printf "%s请输入%s: " "$C_BOLD" "$C_RESET" >&2
    read_line value
    if [[ -z "$value" ]]; then
      err "未输入内容"
      continue
    fi
    if [[ "$value" == "0" ]]; then
      printf '0'
      return 0
    fi
    if [[ "$deployed" != "true" && "$value" != "1" && "$value" != "11" ]]; then
      warn "尚未部署，请先选择 1) 首次安装"
      continue
    fi
    case "$value" in
      1|2|3|4|5|6|7|8|9|10|11)
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
    true|yes|y) printf 'true' ;;
    false|no|n) printf 'false' ;;
    *) err "布尔值无效: $1"; exit 1 ;;
  esac
}

normalize_name() {
  local text="$1"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${text:-node}"
}

get_public_ip() {
  local ip
  ip="$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsSL --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  fi
  printf '%s' "$ip"
}

detect_cpu_flavor() {
  local info
  info="$(tr '[:upper:]' '[:lower:]' </proc/cpuinfo 2>/dev/null || true)"
  if printf '%s' "$info" | grep -Eq 'amd|epyc|ryzen'; then printf 'amd'
  elif printf '%s' "$info" | grep -Eq 'intel|xeon'; then printf 'intel'
  elif printf '%s' "$info" | grep -Eq 'arm|aarch64|graviton'; then printf 'arm'
  else printf 'cpu'; fi
}

detect_mem_label() {
  local kb gb
  kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  gb=$(( (kb + 1024 * 1024 - 1) / (1024 * 1024) ))
  (( gb < 1 )) && gb=1
  printf '%sg' "$gb"
}

detect_city_code() {
  local ip="$1" city code
  city="$(curl -fsSL --max-time 10 "https://ipapi.co/${ip}/city/" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/ //g' || true)"
  case "$city" in
    phoenix) code="phx" ;; sanjose|sanjose*) code="sjc" ;; losangeles) code="lax" ;;
    newyork) code="nyc" ;; chicago) code="chi" ;; dallas) code="dfw" ;;
    seattle) code="sea" ;; miami) code="mia" ;; dubai) code="dxb" ;;
    tokyo) code="tyo" ;; osaka) code="osa" ;; seoul) code="sel" ;;
    singapore) code="sin" ;; london) code="lon" ;; frankfurt) code="fra" ;;
    *) city="$(normalize_name "$city")"; [[ "$city" == "node" ]] && code="x" || code="${city:0:3}" ;;
  esac
  printf '%s' "$code"
}

resolve_node_name() {
  local ip cpu mem city suffix
  if [[ -n "$NODE_NAME" ]]; then normalize_name "$NODE_NAME"; return; fi
  ip="$(get_public_ip)"
  if [[ -z "$ip" ]]; then normalize_name "${TLS_DOMAIN:-node}"; return; fi
  cpu="$(detect_cpu_flavor)"; mem="$(detect_mem_label)"; city="$(detect_city_code "$ip")"; suffix="${ip##*.}"
  normalize_name "${cpu}${mem}-${suffix}-${city}"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\r\n'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid | tr -d '\r\n'
  else err "无法生成 UUID"; exit 1; fi
}

resolve_auth_values() {
  [[ -n "$AUTH_UUID" ]] || AUTH_UUID="$(gen_uuid)"
  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$AUTH_UUID"
  [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$AUTH_UUID"
}

resolve_zone_id() {
  curl -fsSL --max-time 15 -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=$1&status=active" | jq -r '.result[0].id // empty'
}

upsert_cloudflare_a_record() {
  local fqdn="$1" zone_id="$2" token="$3" ip="$4" record_id
  record_id="$(curl -fsSL --max-time 15 -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$fqdn" | jq -r '.result[0].id // empty')"
  if [[ -n "$record_id" ]]; then
    curl -fsSL --max-time 15 -X PUT -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}" | jq -e '.success == true' >/dev/null
    ok "已更新 Cloudflare A 记录: $fqdn -> $ip"
  else
    curl -fsSL --max-time 15 -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}" | jq -e '.success == true' >/dev/null
    ok "已创建 Cloudflare A 记录: $fqdn -> $ip"
  fi
}

prepare_auto_domain() {
  [[ "$AUTO_TLS" == "true" && "$AUTO_DOMAIN" == "true" ]] || return 0
  [[ -n "$BASE_DOMAIN" ]] || { err "AUTO_DOMAIN=true 时必须填写 BASE_DOMAIN"; exit 1; }
  [[ -n "$CF_Token" ]] || { err "AUTO_DOMAIN=true 时必须填写 CF_Token"; exit 1; }
  local ip cpu mem city suffix zone_id
  ip="$(get_public_ip)"; [[ -n "$ip" ]] || { err "无法检测公网 IPv4"; exit 1; }
  cpu="$(detect_cpu_flavor)"; mem="$(detect_mem_label)"; city="$(detect_city_code "$ip")"; suffix="${ip##*.}"
  TLS_DOMAIN="${cpu}${mem}-${suffix}-${city}.${BASE_DOMAIN}"
  zone_id="${CF_Zone_ID:-$(resolve_zone_id "$BASE_DOMAIN" "$CF_Token")}"
  [[ -n "$zone_id" ]] || { err "无法解析 Cloudflare Zone ID"; exit 1; }
  CF_Zone_ID="$zone_id"
  upsert_cloudflare_a_record "$TLS_DOMAIN" "$CF_Zone_ID" "$CF_Token" "$ip"
  ok "已选择自动域名: $TLS_DOMAIN"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then ok "Docker 已安装: $(docker --version)"; return; fi
  log "未找到 Docker，正在自动安装 Docker Engine..."
  [[ -f /etc/os-release ]] || { err "系统不受支持：未找到 /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  local distro="${ID:-}" codename="${VERSION_CODENAME:-}"
  [[ "$distro" == "ubuntu" || "$distro" == "debian" ]] || { err "自动安装仅支持 Ubuntu/Debian，当前系统: ${distro:-unknown}"; exit 1; }
  [[ -n "$codename" ]] || { err "无法识别系统代号，无法配置 Docker apt 源"; exit 1; }
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
  ok "Docker 安装完成"
}

ensure_host_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  [[ ${#missing[@]} -eq 0 ]] && return
  command -v apt-get >/dev/null 2>&1 || { err "缺少命令: ${missing[*]}"; exit 1; }
  log "正在安装必要工具: ${missing[*]}"
  run_root apt-get update -y
  run_root apt-get install -y "${missing[@]}"
}

load_existing_env() {
  [[ -f "$ENV_FILE" ]] || return
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key%$'\r'}"; value="${value%$'\r'}"
    case "$key" in
      HY2_PORT|VLESS_PORT|MIXED_PORT|ENABLE_HY2|ENABLE_VLESS|AUTO_DOMAIN|BASE_DOMAIN|NODE_NAME|AUTH_UUID|HY2_PASSWORD|VLESS_UUID|AUTO_TLS|TLS_DOMAIN|TLS_CERT_PATH|TLS_KEY_PATH|ACME_EMAIL|TLS_ISSUE_RETRIES|TLS_RENEW_INTERVAL|WARP_LICENSE_KEY|CF_Token|CF_Account_ID|CF_Zone_ID)
        printf -v "$key" '%s' "$value" ;;
    esac
  done < "$ENV_FILE"
}

collect_bootstrap_inputs() {
  local mode="${1:-install}"
  if [[ "$mode" == "install" ]]; then
    APP_DIR="$(ask_input "部署目录" "$APP_DIR")"; refresh_paths
    if is_deployed; then err "该目录已有部署，请选择修改配置"; return 1; fi
  fi
  printf '\n%sTLS 配置%s\n' "$C_BOLD" "$C_RESET" >&2
  AUTO_TLS="$(normalize_bool "$(ask_choice "启用自动 TLS (y/n)" "$AUTO_TLS")")"
  if [[ "$AUTO_TLS" == "true" ]]; then
    printf '%s需要 Cloudflare API Token（Zone/DNS/Edit 权限）。%s\n' "$C_DIM" "$C_RESET" >&2
    CF_Token="$(ask_secret "Cloudflare API Token" "$CF_Token")"
    while [[ -z "$CF_Token" ]]; do err "Cloudflare API Token 不能为空"; CF_Token="$(ask_secret "Cloudflare API Token")"; done
    AUTO_DOMAIN="$(normalize_bool "$(ask_choice "自动生成子域名 (y/n)" "$AUTO_DOMAIN")")"
    if [[ "$AUTO_DOMAIN" == "true" ]]; then BASE_DOMAIN="$(ask_input "Cloudflare 主域名 (example.com)" "$BASE_DOMAIN")"; TLS_DOMAIN=""
    else TLS_DOMAIN="$(ask_input "TLS 域名" "$TLS_DOMAIN")"; fi
    ACME_EMAIL="$(ask_input "证书通知邮箱 (建议填写)" "$ACME_EMAIL")"
  else
    AUTO_DOMAIN="false"; CF_Token=""; TLS_DOMAIN="$(ask_input "TLS 域名" "$TLS_DOMAIN")"
    warn "请先将 fullchain.pem 和 privkey.pem 放入 $APP_DIR/certs/"
  fi
  printf '\n%s协议 / 端口配置%s\n' "$C_BOLD" "$C_RESET" >&2
  ENABLE_HY2="$(normalize_bool "$(ask_choice "启用 HY2 (y/n)" "$ENABLE_HY2")")"
  [[ "$ENABLE_HY2" == "true" ]] && HY2_PORT="$(ask_port "HY2 端口" "$HY2_PORT")"
  ENABLE_VLESS="$(normalize_bool "$(ask_choice "启用 VLESS (y/n)" "$ENABLE_VLESS")")"
  [[ "$ENABLE_VLESS" == "true" ]] && VLESS_PORT="$(ask_port "VLESS 端口" "$VLESS_PORT")"
  MIXED_PORT="$(ask_port "本机 Mixed 代理端口（仅 127.0.0.1）" "$MIXED_PORT")"
  if [[ "$(normalize_bool "$(ask_choice "配置高级选项 (y/n)" "n")")" == "true" ]]; then
    IMAGE="$(ask_input "镜像地址" "$IMAGE")"
    NODE_NAME="$(ask_input "节点名称（留空自动生成）" "$NODE_NAME")"
    AUTH_UUID="$(ask_input "AUTH_UUID（留空自动生成）" "$AUTH_UUID")"
    HY2_PASSWORD="$(ask_secret "HY2_PASSWORD（可选）" "$HY2_PASSWORD")"
    VLESS_UUID="$(ask_input "VLESS_UUID（可选）" "$VLESS_UUID")"
    WARP_LICENSE_KEY="$(ask_secret "WARP_LICENSE_KEY（可选）" "$WARP_LICENSE_KEY")"
    TLS_ISSUE_RETRIES="$(ask_input "TLS 签发重试次数" "$TLS_ISSUE_RETRIES")"
    TLS_RENEW_INTERVAL="$(ask_input "TLS 续期间隔秒数" "$TLS_RENEW_INTERVAL")"
  fi
}

confirm_config() {
  local domain_label="$TLS_DOMAIN" node_label
  [[ "$AUTO_DOMAIN" == "true" ]] && domain_label="自动生成 (*.$BASE_DOMAIN)"
  node_label="${NODE_NAME:-自动生成}"
  printf '\n%s配置摘要%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '  部署目录: %s\n  镜像: %s\n  节点名: %s\n  TLS 域名: %s\n' "$APP_DIR" "$IMAGE" "$node_label" "$domain_label" >&2
  printf '  TLS 模式: %s\n' "$([[ "$AUTO_TLS" == "true" ]] && printf '自动签发（Cloudflare Token 已配置）' || printf '手动证书')" >&2
  printf '  HY2: %s%s\n  VLESS: %s%s\n  Mixed: %s（仅本机）\n' \
    "$ENABLE_HY2" "$([[ "$ENABLE_HY2" == true ]] && printf "，端口 $HY2_PORT")" \
    "$ENABLE_VLESS" "$([[ "$ENABLE_VLESS" == true ]] && printf "，端口 $VLESS_PORT")" "$MIXED_PORT" >&2
  printf '  WARP+: %s\n' "$([[ -n "$WARP_LICENSE_KEY" ]] && printf '已配置' || printf '普通 WARP')" >&2
  [[ "$(normalize_bool "$(ask_choice "确认并继续 (y/n)" "y")")" == "true" ]]
}

validate_positive_int() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { err "$name 必须是正整数，当前值: $value"; exit 1; }
}

validate_port() {
  local name="$1" value="$2"
  validate_positive_int "$name" "$value"
  (( 10#$value <= 65535 )) || { err "$name 必须在 1-65535 范围内，当前值: $value"; exit 1; }
}

validate_env_value() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9_./:@%+,-]*$ ]] || { err "$name 包含不支持的字符；请仅使用字母、数字及 _ . / : @ % + , -"; exit 1; }
}

validate_config() {
  validate_bool "$AUTO_TLS"
  [[ "$ENABLE_HY2" == "true" || "$ENABLE_VLESS" == "true" ]] || { err "至少启用一种协议"; exit 1; }
  if [[ "$ENABLE_HY2" == "true" ]]; then validate_port "HY2_PORT" "$HY2_PORT"; fi
  if [[ "$ENABLE_VLESS" == "true" ]]; then validate_port "VLESS_PORT" "$VLESS_PORT"; fi
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
  [[ "$ENABLE_HY2" != "true" || "$MIXED_PORT" != "$HY2_PORT" ]] || { err "HY2 与 Mixed 端口不能重复"; exit 1; }
  [[ "$ENABLE_VLESS" != "true" || "$MIXED_PORT" != "$VLESS_PORT" ]] || { err "VLESS 与 Mixed 端口不能重复"; exit 1; }
  [[ "$ENABLE_HY2" != "true" || "$ENABLE_VLESS" != "true" || "$HY2_PORT" != "$VLESS_PORT" ]] || { err "HY2 与 VLESS 端口不能重复"; exit 1; }
  if [[ "$ENABLE_VLESS" == "true" ]]; then
    local effective_vless_uuid="${VLESS_UUID:-$AUTH_UUID}"
    if [[ -n "$effective_vless_uuid" ]] && ! [[ "$effective_vless_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      err "VLESS_UUID/AUTH_UUID 不是有效的 UUID"
      exit 1
    fi
  fi
  if [[ "$AUTO_TLS" == "true" ]]; then
    [[ -n "$CF_Token" ]] || { err "自动 TLS 需要 Cloudflare API Token"; exit 1; }
    [[ "$AUTO_DOMAIN" == "true" || -n "$TLS_DOMAIN" ]] || { err "请填写 TLS 域名"; exit 1; }
  else
    [[ -s "$APP_DIR/certs/fullchain.pem" && -s "$APP_DIR/certs/privkey.pem" ]] || { err "手动证书模式需要 certs/fullchain.pem 与 certs/privkey.pem"; exit 1; }
  fi
  resolve_auth_values
}

write_compose() {
  local ports_block=""
  [[ "$ENABLE_HY2" == "true" ]] && ports_block+=$'\n      - "${HY2_PORT:-32443}:${HY2_PORT:-32443}/tcp"\n      - "${HY2_PORT:-32443}:${HY2_PORT:-32443}/udp"'
  [[ "$ENABLE_VLESS" == "true" ]] && ports_block+=$'\n      - "${VLESS_PORT:-38443}:${VLESS_PORT:-38443}/tcp"'
  ports_block+=$'\n      - "127.0.0.1:${MIXED_PORT:-1080}:${MIXED_PORT:-1080}/tcp"'
  mkdir -p "$APP_DIR"
  printf '%s\n' "services:
  singbox-warp:
    image: $IMAGE
    container_name: singbox-warp
    restart: unless-stopped
    ports:$ports_block
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
      test: [\"CMD-SHELL\", \"test -s /run/sing-box.pid && kill -0 \\\"\\\$(cat /run/sing-box.pid)\\\" && curl -fsS --max-time 3 --proxy \\\"socks5h://127.0.0.1:\${MIXED_PORT:-1080}\\\" https://cp.cloudflare.com/ >/dev/null\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
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
      - CF_Zone_ID=\${CF_Zone_ID:-}" > "$COMPOSE_FILE"
}

write_env() {
  printf '%s\n' "HY2_PORT=$HY2_PORT
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
CF_Zone_ID=$CF_Zone_ID" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "已保存配置: $ENV_FILE"
}

backup_config() {
  ensure_state_dir
  if [[ -d "$CONFIG_BACKUP_DIR" && ! -w "$CONFIG_BACKUP_DIR" ]]; then
    run_root chown "$(id -u):$(id -g)" "$CONFIG_BACKUP_DIR" 2>/dev/null || true
  fi
  if [[ ! -d "$CONFIG_BACKUP_DIR" ]]; then
    run_root install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$CONFIG_BACKUP_DIR"
  fi
  if [[ -w "$CONFIG_BACKUP_DIR" ]]; then
    cp -f "$ENV_FILE" "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME"
    cp -f "$COMPOSE_FILE" "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME"
  else
    run_root cp -f "$ENV_FILE" "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME"
    run_root cp -f "$COMPOSE_FILE" "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME"
    run_root chown "$(id -u):$(id -g)" "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" 2>/dev/null || true
  fi
}

restore_config() {
  [[ -f "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" && -f "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" ]] || return 1
  if [[ -r "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" && -r "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" && -w "$APP_DIR" ]]; then
    cp -f "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" "$ENV_FILE"
    cp -f "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" "$COMPOSE_FILE"
  else
    run_root cp -f "$CONFIG_BACKUP_DIR/$ENV_FILE_NAME" "$ENV_FILE"
    run_root cp -f "$CONFIG_BACKUP_DIR/$COMPOSE_FILE_NAME" "$COMPOSE_FILE"
    run_root chown "$(id -u):$(id -g)" "$ENV_FILE" "$COMPOSE_FILE" 2>/dev/null || true
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || run_root chmod 600 "$ENV_FILE"
  dcc compose up -d
  warn "已恢复修改前的配置"
}

ensure_state_dir() {
  if [[ -d "$STATE_DIR" && -w "$STATE_DIR" ]]; then
    return 0
  fi
  run_root install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$STATE_DIR"
}

write_state_file() {
  local file="$1" content="$2"
  ensure_state_dir
  if [[ -w "$file" || ! -e "$file" && -w "$STATE_DIR" ]]; then
    printf '%s\n' "$content" > "$file"
  else
    printf '%s\n' "$content" | run_root tee "$file" >/dev/null
    run_root chown "$(id -u):$(id -g)" "$file" 2>/dev/null || true
  fi
}

record_current_image_for_rollback() {
  ensure_state_dir
  if dc inspect singbox-warp >/dev/null 2>&1; then
    local image_id configured_image repo_digest
    image_id="$(dc inspect singbox-warp --format '{{.Image}}')"
    configured_image="$(dc inspect singbox-warp --format '{{.Config.Image}}')"
    if [[ "$configured_image" != sha256:* && "$configured_image" != *@sha256:* ]]; then
      write_state_file "$UPDATE_IMAGE_FILE" "$configured_image"
    fi
    repo_digest="$(dc image inspect "$image_id" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
    write_state_file "$ROLLBACK_FILE" "${repo_digest:-$image_id}"
  fi
}

wait_healthy() {
  local attempts="${1:-30}" status attempt
  for attempt in $(seq 1 "$attempts"); do
    status="$(dc inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' singbox-warp 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then ok "容器健康检查通过"; return 0; fi
    printf '\r%s等待服务就绪: %s/%s（%s）%s' "$C_DIM" "$attempt" "$attempts" "$status" "$C_RESET" >&2
    sleep 2
  done
  printf '\n' >&2
  err "容器未通过健康检查"
  dc logs --tail 80 singbox-warp || true
  return 1
}

cmd_status() {
  if ! container_running; then warn "singbox-warp 容器未运行"; return 1; fi
  dc inspect singbox-warp --format '镜像: {{.Config.Image}}'
  dc inspect singbox-warp --format '健康状态: {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
}

cmd_show_nodes() {
  need_cmd docker
  need_cmd jq
  if ! container_running; then warn "容器未运行，无法读取节点链接"; return 1; fi
  local config hy2_password hy2_port hy2_sni hy2_tag vless_uuid vless_port vless_sni vless_tag vless_flow
  config="$(dc exec singbox-warp cat /etc/sing-box/config.json 2>/dev/null || true)"
  [[ -n "$config" ]] || { err "无法读取容器内配置"; return 1; }
  hy2_password="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "hysteria2") | .users[0].password // empty' | head -n1)"
  hy2_port="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "hysteria2") | .listen_port // empty' | head -n1)"
  hy2_sni="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "hysteria2") | .tls.server_name // empty' | head -n1)"
  hy2_tag="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "hysteria2") | .tag // empty' | head -n1)"
  if [[ -n "$hy2_password" && -n "$hy2_port" && -n "$hy2_sni" ]]; then
    printf '%sHY2%s\n%s\n\n' "$C_BOLD" "$C_RESET" "hy2://${hy2_password}@${hy2_sni}:${hy2_port}?sni=${hy2_sni}&insecure=0#${hy2_tag:-hy2}"
  fi
  vless_uuid="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "vless") | .users[0].uuid // empty' | head -n1)"
  vless_port="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "vless") | .listen_port // empty' | head -n1)"
  vless_sni="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "vless") | .tls.server_name // empty' | head -n1)"
  vless_tag="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "vless") | .tag // empty' | head -n1)"
  vless_flow="$(printf '%s\n' "$config" | jq -r '.inbounds[]? | select(.type == "vless") | .users[0].flow // empty' | head -n1)"
  if [[ -n "$vless_uuid" && -n "$vless_port" && -n "$vless_sni" ]]; then
    local vless_link="vless://${vless_uuid}@${vless_sni}:${vless_port}?encryption=none&security=tls&sni=${vless_sni}&type=tcp"
    [[ -z "$vless_flow" ]] || vless_link+="&flow=${vless_flow}"
    printf '%sVLESS%s\n%s#%s\n' "$C_BOLD" "$C_RESET" "$vless_link" "${vless_tag:-vless}"
  fi
}

replace_compose_image() {
  local image="$1"
  awk -v replacement="$image" '
    /^[[:space:]]*image:[[:space:]]*/ {
      match($0, /^[[:space:]]*image:[[:space:]]*/)
      print substr($0, 1, RLENGTH) replacement
      next
    }
    { print }
  ' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp"
  mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
}

cmd_bootstrap() {
  collect_bootstrap_inputs install || return
  validate_config
  confirm_config || { log "已取消安装"; return; }
  ensure_docker
  ensure_host_tools
  prepare_auto_domain
  NODE_NAME="$(resolve_node_name)"
  mkdir -p "$APP_DIR"/{data,certs,acme}
  write_compose
  write_env
  log "正在拉取镜像，请稍候..."
  dcc compose pull
  log "正在启动服务..."
  dcc compose up -d
  wait_healthy 180 || { err "首次安装失败，请查看上方容器日志"; return 1; }
  persist_active_app_dir
  ok "部署完成: $APP_DIR"
  printf '\n'
  cmd_show_nodes
}

cmd_update_image() {
  ensure_docker
  record_current_image_for_rollback
  log "正在拉取最新镜像，请稍候..."
  if ! dcc compose pull || ! dcc compose up -d; then
    err "镜像更新失败"
    return 1
  fi
  wait_healthy || { err "新镜像健康检查失败"; return 1; }
  ok "镜像更新完成，配置未改变"
}

cmd_edit_config() {
  load_existing_env
  collect_bootstrap_inputs edit
  validate_config
  confirm_config || { log "已取消修改"; return; }
  backup_config
  ensure_docker
  ensure_host_tools
  prepare_auto_domain
  NODE_NAME="$(resolve_node_name)"
  write_compose
  write_env
  log "正在应用新配置..."
  if ! dcc compose up -d || ! wait_healthy; then
    err "新配置未通过验证，正在恢复旧配置"
    restore_config || err "旧配置恢复失败，请检查 $CONFIG_BACKUP_DIR"
    return 1
  fi
  ok "配置修改完成"
  printf '\n'
  cmd_show_nodes
}

cmd_diagnose() {
  ensure_docker
  load_existing_env
  [[ -f "$COMPOSE_FILE" ]] && ok "Compose 文件存在" || { err "缺少 $COMPOSE_FILE"; return 1; }
  if dcc compose config -q; then ok "Compose 配置有效"; else err "Compose 配置无效"; return 1; fi
  if container_running; then ok "容器正在运行"; else err "容器未运行"; return 1; fi
  if wait_healthy 1; then :; else warn "容器尚未健康"; fi
  if [[ -n "$TLS_DOMAIN" ]]; then
    if getent ahostsv4 "$TLS_DOMAIN" >/dev/null 2>&1; then ok "域名可解析: $TLS_DOMAIN"; else warn "无法确认域名解析: $TLS_DOMAIN"; fi
  fi
  if curl -fsSL --max-time 10 --proxy "socks5h://127.0.0.1:$MIXED_PORT" https://api.ipify.org >/dev/null; then ok "Mixed/WARP 出口可用"; else warn "Mixed/WARP 出口不可用"; fi
}

cmd_logs() { dc logs --tail 100 -f singbox-warp || true; }

cmd_restart() {
  log "正在重启服务..."
  dc restart singbox-warp >/dev/null
  wait_healthy || return 1
  ok "服务重启完成"
}

cmd_rollback() {
  [[ -s "$ROLLBACK_FILE" ]] || { warn "没有可回滚的镜像记录"; return 1; }
  local image
  image="$(head -n1 "$ROLLBACK_FILE")"
  log "正在回滚到: $image"
  replace_compose_image "$image"
  dcc compose up -d
  wait_healthy || return 1
  ok "回滚完成"
}

current_script_path() {
  local script_path="${BASH_SOURCE[0]}"
  if [[ "$script_path" != /* ]]; then
    script_path="$PWD/$script_path"
  fi
  printf '%s' "$script_path"
}

cmd_update_script() {
  need_cmd curl
  local script_path tmp_script new_version
  script_path="$(current_script_path)"
  tmp_script="$(mktemp /tmp/swd-update.XXXXXX)"
  log "正在从 GitHub 拉取最新脚本..."
  if ! curl -fsSL --max-time 30 "$SCRIPT_UPDATE_URL" -o "$tmp_script"; then
    err "下载失败: $SCRIPT_UPDATE_URL"
    rm -f "$tmp_script"
    return 1
  fi
  if ! bash -n "$tmp_script"; then
    err "新脚本语法检查失败，已取消更新"
    rm -f "$tmp_script"
    return 1
  fi
  new_version="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$tmp_script" | head -n1)"
  if [[ -z "$new_version" ]]; then
    err "新脚本缺少 SCRIPT_VERSION，已取消更新"
    rm -f "$tmp_script"
    return 1
  fi
  if [[ "$new_version" == "$SCRIPT_VERSION" ]]; then
    ok "脚本已是最新版本: v$SCRIPT_VERSION"
    rm -f "$tmp_script"
    return 0
  fi
  printf '当前版本: v%s\n新版本: v%s\n' "$SCRIPT_VERSION" "$new_version" >&2
  [[ "$(normalize_bool "$(ask_choice "确认更新脚本 (y/n)" "y")")" == "true" ]] || { log "已取消更新"; rm -f "$tmp_script"; return 0; }
  chmod 0755 "$tmp_script"
  if [[ -w "$(dirname "$script_path")" && -w "$script_path" ]]; then
    mv -f "$tmp_script" "$script_path"
  else
    run_root install -m 0755 "$tmp_script" "$script_path"
    rm -f "$tmp_script"
  fi
  ok "脚本已更新到 v$new_version: $script_path"
  warn "请重新运行脚本以使用新版本"
  exit 0
}

cmd_uninstall() {
  printf '\n%s卸载会停止并删除容器及网络，但默认保留 data、certs、acme 和配置文件。%s\n' "$C_YELLOW" "$C_RESET" >&2
  [[ "$(normalize_bool "$(ask_choice "确认卸载服务 (y/n)" "n")")" == "true" ]] || { log "已取消卸载"; return; }
  ensure_docker
  log "正在停止并删除容器..."
  dcc compose down --remove-orphans
  if [[ "$(normalize_bool "$(ask_choice "同时删除 $APP_DIR 的全部数据（不可恢复）(y/n)" "n")")" == "true" ]]; then
    run_root rm -rf "$APP_DIR"
    ok "服务与全部数据已删除"
  else
    ok "服务已卸载，配置和数据仍保留在 $APP_DIR"
  fi
}

main() {
  load_active_app_dir
  self_install_swd
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then usage; return; fi
  [[ -z "${1:-}" ]] || { err "此脚本仅支持交互模式"; usage; exit 1; }
  print_banner
  while true; do
    local deployed="false"
    is_deployed && deployed="true"
    case "$(ask_menu_choice "$deployed")" in
      0) log "退出"; return ;;
      1) cmd_bootstrap || true ;;
      2) cmd_update_image || true ;;
      3) cmd_edit_config || true ;;
      4) cmd_show_nodes || true ;;
      5) cmd_status || true ;;
      6) cmd_diagnose || true ;;
      7) cmd_logs ;;
      8) cmd_restart || true ;;
      9) cmd_rollback || true ;;
      10) cmd_uninstall || true ;;
      11) cmd_update_script || true ;;
    esac
  done
}

main "$@"
