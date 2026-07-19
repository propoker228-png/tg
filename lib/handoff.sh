#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

show_mtproxybot_handoff() {
  local domain="$1"
  local link
  link=$(fetch_proxy_link 2>/dev/null || echo "н/д")

  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Данные для @MTProxybot${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════${NC}"
  echo -e "  Сервер:  ${CYAN}${domain}:443${NC}"
  echo -e "  Секрет:  ${CYAN}${SECRET}${NC}"
  echo -e "  Ссылка:  ${CYAN}${link}${NC}"
  show_proxy_online_stats
  echo "  1. @MTProxybot → /newproxy"
  echo "  2. Отправьте сервер и секрет (НЕ ссылку от бота!)"
  echo "  3. /myproxies → Set promotion → публичный канал"
  echo -e "${BOLD}══════════════════════════════════════════════${NC}"
  echo ""
}

prompt_ad_tag() {
  [ -n "${AD_TAG:-}" ] && return 0

  log_info "ad_tag появится в @MTProxybot после регистрации прокси (сервер + секрет)."
  log_info "При первой установке нажмите Enter — добавите позже в меню: 5) Настройки прокси"

  local attempt=0 tag=""
  while [ "$attempt" -lt 3 ]; do
    prompt_line tag "ad_tag из @MTProxybot (Enter = пропустить)" ""
    [ -z "$tag" ] && return 0
    if is_valid_ad_tag "$tag"; then
      AD_TAG="$tag"
      export AD_TAG
      return 0
    fi
    log_warn "ad_tag должен быть 32 hex-символа"
    attempt=$((attempt + 1))
  done
  log_warn "ad_tag пропущен после 3 попыток"
}
