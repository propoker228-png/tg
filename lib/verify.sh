#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

verify_install() {
  local domain="$1"
  local fail=0
  local link=""

  for svc in telemt nginx; do
    systemctl is-active --quiet "$svc" || { log_err "$svc не active"; fail=1; }
  done

  if [ "${MEKO_FULL:-0}" -eq 0 ]; then
    systemctl is-active --quiet mtpr-synfix || { log_err "mtpr-synfix не active"; fail=1; }
    iptables -L MTPR_SYNFIX -n 2>/dev/null | grep -q 443 || { log_err "MTPR_SYNFIX нет правил"; fail=1; }
  fi

  if wait_telemt_port_443 30; then
    log_ok "telemt слушает порт 443"
  else
    log_err "443 не слушает telemt (после 30 с ожидания)"
    ss -tlnp 2>/dev/null | grep ':443 ' >&2 || log_err "порт 443 никто не слушает" >&2
    fail=1
  fi

  local code
  code=$(wait_mask_site_http "$domain" 200 20 || true)
  if [ "$code" = "200" ]; then
    log_ok "mask site отвечает HTTP 200"
  else
    log_err "mask site HTTP $code (ожидали 200)"
    fail=1
  fi

  if link=$(wait_proxy_link 20); then
    log_ok "ссылка получена из API"
  else
    log_err "не удалось получить ссылку из API"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    log_ok "Все проверки пройдены"
  else
    log_warn "Часть проверок не прошла — установка продолжена"
    link="${link:-$(fetch_proxy_link 2>/dev/null || true)}"
  fi

  if [ -n "$link" ]; then
    echo ""
    echo -e "${BOLD}Ссылка:${NC} $link"
    export PROXY_LINK="$link"
  fi

  show_proxy_online_stats

  return "$fail"
}
