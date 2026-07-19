#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

UI_HIGHLIGHT_SH_VERSION="1.0"

hl_domain() {
  echo -e "${CYAN}${BOLD}$1${NC}"
}

hl_telemt_version() {
  local version="$1" suffix="${2:-}"
  if [ -n "$suffix" ]; then
    echo -e "${GREEN}${BOLD}${version}${NC} ${YELLOW}${suffix}${NC}"
  else
    echo -e "${GREEN}${BOLD}${version}${NC}"
  fi
}

hl_meko() {
  local mode="$1" version="$2"
  echo -e "${YELLOW}${BOLD}${mode} v${version}${NC}"
}

hl_adtag() {
  if [ -n "${1:-}" ]; then
    echo -e "${MAGENTA}${BOLD}$1${NC}"
  else
    echo -e "${GRAY}не задан${NC}"
  fi
}

hl_ssl() {
  echo -e "${BLUE}${BOLD}Let's Encrypt → :443${NC}"
}

print_install_summary() {
  local meko_mode="inline SYN FIX"
  [ "${MEKO_FULL:-0}" -eq 1 ] && meko_mode="MEKO Launcher (full)"

  echo ""
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo -e "${BOLD}  Параметры установки${NC}"
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo -e "  Домен:      $(hl_domain "$DOMAIN")"
  echo -e "  SSL:        $(hl_ssl)"
  echo -e "  telemt:     $(hl_telemt_version "${TELEMT_VERSION}" "${TELEMT_VERSION_HINT:-}")"
  echo -e "  MEKO:       $(hl_meko "$meko_mode" "${MEKO_VERSION:-$(meko_bundled_version)}")"
  echo -e "  ad_tag:     $(hl_adtag "${AD_TAG:-}")"
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo ""
}

prompt_ad_tag_colored() {
  [ -n "${AD_TAG:-}" ] && return 0

  local attempt=0 tag=""
  while [ "$attempt" -lt 3 ]; do
    prompt_msg "${BOLD}ad_tag из @MTProxybot${NC} ${GRAY}(Enter = пропустить)${NC}: "
    if ! prompt_read_into tag; then
      die "Не удалось прочитать ввод. Запустите интерактивно: sudo bash install.sh"
    fi
    tag="$(trim_whitespace "$tag")"
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
