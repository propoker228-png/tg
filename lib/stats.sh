#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STATS_SH_VERSION="2.4.0"
TELEMT_API_URL="${TELEMT_API_URL:-http://127.0.0.1:9091}"

telemt_api_curl() {
  local path="$1"
  curl -fsS --max-time 3 --connect-timeout 2 "${TELEMT_API_URL}${path}" 2>/dev/null
}

telemt_users_json() {
  telemt_api_curl "/v1/users"
}

# Как в MEKO Launcher: /v1/stats/users/active-ips + подсчёт IPv4 в active_ips
fetch_proxy_online_people() {
  local json count

  json=$(curl -fsS --max-time 2 --connect-timeout 1 \
    "${TELEMT_API_URL}/v1/stats/users/active-ips" 2>/dev/null) || json=""

  if [ -z "$json" ]; then
    echo "0"
    return 0
  fi

  count=$(printf '%s' "$json" \
    | grep -o '"active_ips":\[[^]]*\]' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | wc -l | tr -d '[:space:]')

  echo "${count:-0}"
}

_service_status_label() {
  systemctl is-active --quiet "$1" 2>/dev/null && echo OK || echo FAIL
}

fetch_active_ips_list() {
  local json
  json=$(curl -fsS --max-time 2 --connect-timeout 1 \
    "${TELEMT_API_URL}/v1/stats/users/active-ips" 2>/dev/null) || json=""
  [ -n "$json" ] || return 0
  printf '%s' "$json" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
}

render_menu_header() {
  local installer_ver="${1:-2.4}"
  local telemt_ver="н/д" people="0" conns="0"

  env_load_settings
  [ -x /bin/telemt ] && telemt_ver=$(/bin/telemt --version 2>/dev/null | head -1 || echo "н/д")

  if systemctl is-active --quiet telemt 2>/dev/null; then
    people=$(fetch_proxy_online_people)
    conns=$(fetch_proxy_connections_total)
  fi

  echo "=============================================="
  echo "  telemt-deploy v${installer_ver}"
  echo "=============================================="
  if [ -n "${DOMAIN:-}" ]; then
    echo "  домен: ${DOMAIN}:443"
  else
    echo "  домен: не задан"
  fi
  echo "  telemt: ${telemt_ver}"
  if [ "$(meko_install_mode 2>/dev/null || echo none)" = "inline" ]; then
    echo "  meko syn fix: v$(meko_installed_version 2>/dev/null || echo н/д)"
  fi
  echo -e "  подключено: ${YELLOW}${people}${NC} человек | TCP: ${conns}"
  echo "  telemt: $(_service_status_label telemt)  nginx: $(_service_status_label nginx)  mtpr-synfix: $(_service_status_label mtpr-synfix)"
  echo "=============================================="
}

show_stats_snapshot() {
  local ip link count=0

  clear
  render_menu_header "${INSTALLER_VERSION:-2.4}"
  echo ""
  echo "  Активные IP:"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    echo "    $ip"
    count=$((count + 1))
  done < <(fetch_active_ips_list)
  [ "$count" -eq 0 ] && echo "    (нет)"
  echo ""
  link=$(fetch_proxy_link 2>/dev/null || true)
  [ -n "$link" ] && echo -e "  ${BOLD}Ссылка:${NC} ${link}"
  echo ""
}

fetch_proxy_connections_total() {
  local json
  json=$(telemt_users_json) || json=""
  [ -n "$json" ] || { echo "0"; return 0; }
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin).get('data') or []
    print(sum(int(u.get('current_connections') or 0) for u in data))
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

show_proxy_online_stats() {
  local people conns telemt_ver="н/д" port="443"

  if ! systemctl is-active --quiet telemt 2>/dev/null; then
    log_warn "telemt не запущен — статистика подключений недоступна"
    return 1
  fi

  [ -x /bin/telemt ] && telemt_ver=$(/bin/telemt --version 2>/dev/null | head -1 || echo "н/д")
  people=$(fetch_proxy_online_people)
  conns=$(fetch_proxy_connections_total)

  echo ""
  echo -e "  ${CYAN}Telemt:${NC} ${telemt_ver}   ${CYAN}Порт:${NC} ${port}"
  echo -e "  ${BOLD}Подключено к прокси Telemt:${NC} ${YELLOW}${people}${NC} человек"
  echo -e "  ${CYAN}TCP-соединений:${NC} ${conns}"
  echo ""
}

show_proxy_status_panel() {
  local link

  echo ""
  render_menu_header "${INSTALLER_VERSION:-2.4}"
  link=$(fetch_proxy_link 2>/dev/null || true)
  [ -n "$link" ] && echo -e "  ${BOLD}Ссылка:${NC} ${link}"
  echo ""
}
