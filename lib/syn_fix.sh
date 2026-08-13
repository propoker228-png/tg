#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=zapret2.sh
source "$(dirname "${BASH_SOURCE[0]}")/zapret2.sh"

SYN_FIX_SH_VERSION="1.1"
SYN_FIX_MODE="${SYN_FIX_MODE:-meko}"

syn_fix_label() {
  case "${1:-$SYN_FIX_MODE}" in
    zapret2) echo "Zapret2 MTProto fix" ;;
    meko) echo "MEKO SYN FIX" ;;
    none) echo "без SYN-фикса" ;;
    *) echo "${1:-unknown}" ;;
  esac
}

is_valid_syn_fix_mode() {
  case "$1" in
    meko|zapret2|none) return 0 ;;
    *) return 1 ;;
  esac
}

syn_fix_resolve() {
  local raw="${1:-}"
  raw="${raw// /-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    1|meko|syn|hashlimit) printf '%s' "meko" ;;
    2|zapret2|zapret|nfq) printf '%s' "zapret2" ;;
    3|none|off|skip) printf '%s' "none" ;;
    *)
      if is_valid_syn_fix_mode "$raw"; then
        printf '%s' "$raw"
      else
        return 1
      fi
      ;;
  esac
}

syn_fix_is_meko() { [ "${SYN_FIX_MODE:-meko}" = "meko" ]; }
syn_fix_is_zapret2() { [ "${SYN_FIX_MODE:-meko}" = "zapret2" ]; }
syn_fix_is_none() { [ "${SYN_FIX_MODE:-meko}" = "none" ]; }

syn_fix_remove_others() {
  case "${SYN_FIX_MODE:-meko}" in
    zapret2)
      systemctl stop mtpr-synfix 2>/dev/null || true
      systemctl disable mtpr-synfix 2>/dev/null || true
      iptables -t filter -D INPUT -j MTPR_SYNFIX 2>/dev/null || true
      iptables -t filter -F MTPR_SYNFIX 2>/dev/null || true
      iptables -t filter -X MTPR_SYNFIX 2>/dev/null || true
      ;;
    meko)
      zapret2_remove
      ;;
    none)
      systemctl stop mtpr-synfix "$ZAPRET2_SERVICE" 2>/dev/null || true
      zapret2_remove
      iptables -t filter -D INPUT -j MTPR_SYNFIX 2>/dev/null || true
      iptables -t filter -F MTPR_SYNFIX 2>/dev/null || true
      iptables -t filter -X MTPR_SYNFIX 2>/dev/null || true
      ;;
  esac
}

pick_syn_fix_mode() {
  local force_interactive="${1:-0}"
  local choice="" resolved=""
  if [ -n "${SYN_FIX_MODE:-}" ] && [ "${SYN_FIX_MODE_CLI_SET:-0}" -eq 1 ]; then
    resolved=$(syn_fix_resolve "$SYN_FIX_MODE") || die "Неизвестный SYN-фикс: $SYN_FIX_MODE"
    SYN_FIX_MODE="$resolved"
    export SYN_FIX_MODE
    log_ok "SYN-фикс: $(syn_fix_label)"
    return 0
  fi
  if [ "$force_interactive" != "1" ] && [ -n "${SYN_FIX_MODE:-}" ] && is_valid_syn_fix_mode "$SYN_FIX_MODE"; then
    export SYN_FIX_MODE
    return 0
  fi
  if is_auto_mode; then
    SYN_FIX_MODE="${SYN_FIX_MODE:-meko}"
    export SYN_FIX_MODE
    log_info "SYN-фикс (по умолчанию): $(syn_fix_label)"
    return 0
  fi
  echo ""
  echo -e "${BOLD}=== SYN-фикс / обход DPI ===${NC}"
  echo "  1) MEKO SYN FIX — hashlimit (iptables, по умолчанию)"
  echo "  2) Zapret2 MTProto fix — disorder/badsum (как в MTProxyL)"
  echo "  3) Без SYN-фикса"
  while true; do
    prompt_line choice "Выбор [1-3]" "1"
    resolved=$(syn_fix_resolve "$choice") && break
    log_warn "Введите 1, 2 или 3"
  done
  SYN_FIX_MODE="$resolved"
  export SYN_FIX_MODE
  log_ok "SYN-фикс: $(syn_fix_label)"
}

syn_fix_prompt_and_apply() {
  local target="$1" resolved="" prev=""
  resolved=$(syn_fix_resolve "$target") || die "Неизвестный режим SYN-фикса: $target"
  prev="${SYN_FIX_MODE:-meko}"
  if [ "$prev" = "$resolved" ]; then
    if confirm_action "Переустановить $(syn_fix_label "$resolved")?"; then
      syn_fix_install && save_state
    fi
    return 0
  fi
  SYN_FIX_MODE="$resolved"
  export SYN_FIX_MODE
  if confirm_action "Переключить на $(syn_fix_label)? Текущий фикс будет заменён."; then
    syn_fix_install && save_state
  else
    if declare -f env_load_settings >/dev/null 2>&1; then
      env_load_settings 2>/dev/null || true
    fi
    SYN_FIX_MODE="${SYN_FIX_MODE:-$prev}"
    export SYN_FIX_MODE
  fi
}

syn_fix_install() {
  PROXY_PORT="${PROXY_PORT:-443}"
  export PROXY_PORT
  syn_fix_remove_others
  case "$SYN_FIX_MODE" in
    zapret2) zapret2_install ;;
    meko) meko_install ;;
    none) log_info "SYN-фикс пропущен" ;;
    *) die "Неизвестный SYN_FIX_MODE: $SYN_FIX_MODE" ;;
  esac
}

syn_fix_upgrade_if_needed() {
  syn_fix_is_meko || return 0
  meko_upgrade_if_needed
}
