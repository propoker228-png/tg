#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"

LINK_SH_VERSION="1.0"

build_proxy_link_fallback() {
  local domain="${DOMAIN:-}" secret="${SECRET:-}" sni
  env_load_settings 2>/dev/null || true

  if [ -f /etc/telemt/telemt.toml ]; then
    [ -n "$domain" ] || domain=$(awk -F'"' '/^public_host = / { print $2; exit }' /etc/telemt/telemt.toml)
    [ -n "$secret" ] || secret=$(awk -F'"' '/^default = / { print $2; exit }' /etc/telemt/telemt.toml)
    sni=$(awk -F'"' '/^tls_domain = / { print $2; exit }' /etc/telemt/telemt.toml)
  fi

  [ -n "$domain" ] && [ -n "$secret" ] || return 1
  sni="${sni:-$domain}"
  local hex_domain
  hex_domain=$(printf '%s' "$sni" | od -An -tx1 | tr -d ' \n')
  printf 'tg://proxy?server=%s&port=443&secret=ee%s%s' "$domain" "$secret" "$hex_domain"
}

show_proxy_link() {
  local want_qr=0 link tg_link
  [ "${1:-}" = "--qr" ] && want_qr=1

  env_load_settings 2>/dev/null || true
  link=$(fetch_proxy_link 2>/dev/null || true)
  if [ -z "$link" ]; then
    link=$(build_proxy_link_fallback 2>/dev/null || true)
    [ -n "$link" ] && log_warn "API недоступен — ссылка собрана из конфига"
  fi
  [ -n "$link" ] || die "Не удалось получить ссылку прокси"

  echo ""
  echo -e "${BOLD}=== Ссылка прокси ===${NC}"
  [ -n "${DOMAIN:-}" ] && echo -e "  Домен: $(hl_domain "$DOMAIN")"
  echo -e "  ${GREEN}${BOLD}${link}${NC}"
  if [[ "$link" == tg://proxy?* ]]; then
    echo -e "  ${CYAN}https://t.me/${link#tg://}${NC}"
  fi
  echo ""

  if [ "$want_qr" -eq 1 ]; then
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$link"
    else
      log_warn "qrencode не установлен — apt install qrencode"
    fi
  fi
}
