#!/bin/bash
# lib/common.sh — shared utilities for telemt-deploy

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMMON_SH_VERSION="2.3"
TELEMT_BASELINE_VERSION="3.4.23"
SECRET_FILE="/root/telemt-secret.txt"
STATE_FILE="/root/telemt-deploy.state"

# Colors
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; GRAY='\033[0;90m'
  BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; GRAY=''
  BOLD=''; NC=''
fi

log_info()  { echo -e "${BLUE}[i]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()   { echo -e "${RED}[✗]${NC} $*" >&2; }

die() { log_err "$*"; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo bash install.sh"
}

require_ubuntu() {
  [ -f /etc/os-release ] || die "Не удалось определить ОС"
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "$ID" = "ubuntu" ] || die "Поддерживается только Ubuntu (найдено: $ID)"
  case "$VERSION_ID" in
    22.04|24.04) ;;
    *) die "Поддерживается Ubuntu 22.04/24.04 (найдено: $VERSION_ID)" ;;
  esac
}

get_public_ip() {
  curl -fsS --max-time 10 ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

telemt_listens_443() {
  local pid listeners
  pid=$(systemctl show telemt -p MainPID --value 2>/dev/null || echo 0)
  listeners=$(ss -tlnp 2>/dev/null | grep ':443 ' || true)
  if [ -z "$listeners" ]; then
    return 1
  fi
  if echo "$listeners" | grep -qE 'telemt|/bin/telemt'; then
    return 0
  fi
  if [ "$pid" != "0" ] && echo "$listeners" | grep -q "pid=${pid}"; then
    return 0
  fi
  return 1
}

port_in_use() {
  local port="$1"
  ss -tlnH "sport = :$port" 2>/dev/null | grep -q . || return 1
  return 0
}

wait_telemt_port_443() {
  local attempt max="${1:-30}"
  for attempt in $(seq 1 "$max"); do
    if telemt_listens_443; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_mask_site_http() {
  local domain="$1" expected="${2:-200}" attempt max="${3:-20}"
  local code="000"
  for attempt in $(seq 1 "$max"); do
    code=$(curl -sk "https://${domain}/" --resolve "${domain}:443:127.0.0.1" \
      -o /dev/null -w '%{http_code}' --max-time 8 2>/dev/null || echo "000")
    [ "$code" = "$expected" ] && { echo "$code"; return 0; }
    sleep 1
  done
  echo "$code"
  return 1
}

fetch_proxy_link() {
  curl -fsS http://127.0.0.1:9091/v1/users 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])" 2>/dev/null
}

wait_proxy_link() {
  local attempt link max="${1:-20}"
  for attempt in $(seq 1 "$max"); do
    link=$(fetch_proxy_link 2>/dev/null || true)
    [ -n "$link" ] && { echo "$link"; return 0; }
    sleep 1
  done
  return 1
}

render_template() {
  local tpl="$1" dest="$2"
  export DOMAIN SECRET AD_TAG_LINE
  envsubst '${DOMAIN} ${SECRET} ${AD_TAG_LINE}' < "$tpl" > "$dest"
}

version_gt() {
  # usage: version_gt "3.4.24" "3.4.23" → true
  if [ "$1" = "$2" ]; then
    return 1
  fi
  printf '%s\n' "$2" "$1" | sort -C -V
}

trim_whitespace() {
  local value="$1"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_domain_name() {
  local domain
  domain="$(trim_whitespace "$1")"
  domain="${domain%.}"
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$domain"
}

is_valid_domain_label() {
  local label="$1"
  [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
  [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

is_valid_domain_name() {
  local domain="$1" label label_count=0

  [ "${#domain}" -le 253 ] || return 1
  [ "${#domain}" -ge 3 ] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$domain" != *..* ]] || return 1

  local IFS='.'
  for label in $domain; do
    label_count=$((label_count + 1))
    is_valid_domain_label "$label" || return 1
  done

  [ "$label_count" -ge 2 ]
}

require_valid_domain_name() {
  local domain
  domain="$(normalize_domain_name "$1")"
  is_valid_domain_name "$domain" || die "Некорректный домен: $(trim_whitespace "$1")"
  printf '%s' "$domain"
}

is_valid_ad_tag() {
  local tag="$1"
  [[ "$tag" =~ ^[0-9a-fA-F]{32}$ ]]
}

require_valid_ad_tag() {
  local tag="$1"
  is_valid_ad_tag "$tag" || die "ad_tag должен быть 32 hex-символа"
}

is_valid_telemt_version() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}([._+-][A-Za-z0-9.-]+)?$ ]]
}

require_valid_telemt_version() {
  local version="$1"
  is_valid_telemt_version "$version" || die "Некорректная версия telemt: $version"
}

is_valid_meko_version() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

require_valid_meko_version() {
  local version="$1"
  is_valid_meko_version "$version" || die "Некорректная версия MEKO: $version"
}

confirm_yes() {
  local prompt="${1:-Продолжить?}"
  if is_auto_mode; then
    return 0
  fi
  local ans=""
  prompt_msg "${BOLD}${prompt} [y/N]:${NC} "
  prompt_read ans
  [[ "$ans" =~ ^[yY]$ ]]
}

is_auto_mode() {
  [ "${YES:-0}" -eq 1 ]
}

prompt_msg() {
  if [ -w /dev/tty ] 2>/dev/null; then
    printf '%b' "$*" >/dev/tty
  else
    printf '%b' "$*" >&2
  fi
}

prompt_read_into() {
  local -n _ref="$1"
  local buf=""
  if [ -r /dev/tty ] && read -r buf </dev/tty 2>/dev/null; then
    _ref="${buf//$'\r'/}"
    return 0
  fi
  if [ -t 0 ] && read -r buf; then
    _ref="${buf//$'\r'/}"
    return 0
  fi
  return 1
}

prompt_read() {
  local -n _out="$1"
  if ! prompt_read_into _out; then
    if is_auto_mode; then
      _out=""
    else
      die "Не удалось прочитать ввод. Запустите интерактивно: sudo bash install.sh"
    fi
  fi
}

prompt_line() {
  local -n _out="$1"
  local __prompt="$2" __default="${3:-}"
  if [ -n "$__default" ]; then
    prompt_msg "${BOLD}${__prompt}${NC} [${__default}]: "
  else
    prompt_msg "${BOLD}${__prompt}${NC}: "
  fi
  if ! prompt_read_into _out; then
    if is_auto_mode; then
      _out="$__default"
    else
      die "Не удалось прочитать ввод. Запустите интерактивно: sudo bash install.sh"
    fi
  fi
  _out="$(trim_whitespace "${_out:-$__default}")"
}

prompt_choice_12() {
  local -n _result="$1"
  local __title="$2" choice=""
  while true; do
    echo ""
    echo -e "${BOLD}${__title}${NC}"
    echo "  1) Удалить и установить с чистого листа"
    echo "  2) Оставить как есть"
    prompt_line choice "Ваш выбор [1/2]" ""
    case "$choice" in
      1|reinstall|удалить) _result="reinstall"; return 0 ;;
      2|keep|оставить) _result="keep"; return 0 ;;
      "") log_warn "Введите 1 или 2" ;;
      *) log_warn "Введите 1 или 2" ;;
    esac
  done
}

save_state() {
  cat > "$STATE_FILE" <<EOF
DOMAIN=$DOMAIN
SECRET=$SECRET
AD_TAG=${AD_TAG:-}
TELEMT_VERSION=${TELEMT_VERSION:-}
MEKO_VERSION=${MEKO_VERSION:-}
MEKO_FULL=${MEKO_FULL:-0}
DEPLOY_ROOT=$DEPLOY_ROOT
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$STATE_FILE"
}
