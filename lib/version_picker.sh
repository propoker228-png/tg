#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=dialog.sh
source "$(dirname "${BASH_SOURCE[0]}")/dialog.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"

VERSION_PICKER_SH_VERSION="1.0"

TELEMT_GITHUB_REPO="telemt/telemt"
MEKO_GITHUB_REPO="Mekotofeuka/MTPROTO_FIX_By_MEKO"
MEKO_RAW_BASE="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO"

require_tty_for_picker() {
  has_tty || die "Интерактивный выбор версий требует TTY. Запустите: sudo bash install.sh"
}

github_fetch_json() {
  local repo="$1"
  curl -fsSL --max-time 20 -H "User-Agent: telemt-deploy" \
    "https://api.github.com/repos/${repo}/releases?per_page=30"
}

parse_release_versions_from_json() {
  local json="$1" max="${2:-4}"
  printf '%s' "$json" | jq -r '.[].tag_name' 2>/dev/null \
    | sed 's/^v//' | awk 'NF' | sort -V -r | head -n "$max"
}

fetch_telemt_release_versions() {
  local json versions
  json=$(github_fetch_json "$TELEMT_GITHUB_REPO" 2>/dev/null) || true
  if [ -n "$json" ]; then
    versions=$(parse_release_versions_from_json "$json" 4)
  fi
  if [ -z "$versions" ]; then
    log_warn "Не удалось получить релизы telemt с GitHub — используем baseline ${TELEMT_BASELINE_VERSION}"
    versions="$TELEMT_BASELINE_VERSION"
  fi
  printf '%s\n' "$versions"
}

fetch_meko_release_versions() {
  local json versions bundled
  bundled="$(meko_bundled_version)"
  json=$(github_fetch_json "$MEKO_GITHUB_REPO" 2>/dev/null) || true
  if [ -n "$json" ]; then
    versions=$(printf '%s' "$json" | jq -r '.[].tag_name' 2>/dev/null \
      | sed 's/^v//' | awk 'NF' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V -r | head -n 4)
  fi
  if [ -z "$versions" ]; then
    log_warn "Не удалось получить релизы MEKO с GitHub — используем bundled v${bundled}"
    versions="$bundled"
  fi
  printf '%s\n' "$versions"
}

_pick_version_from_list() {
  local title="$1" preselect="${2:-}" mark_latest="${3:-0}"
  shift 3
  local -a items=("$@")
  local count="${#items[@]}"
  local i choice label tag

  [ "$count" -gt 0 ] || die "Список версий пуст"

  if has_dialog && has_tty; then
    local -a menu_args=()
    for i in "${!items[@]}"; do
      tag="${items[$i]}"
      label="$tag"
      [ "$i" -eq 0 ] && label="${tag} ★ latest"
      [ -n "$preselect" ] && [ "$tag" = "$preselect" ] && label="${label} (из флага)"
      menu_args+=("$((i + 1))" "$label")
    done
    choice=$(dialog --clear --stdout --backtitle "telemt-deploy" \
      --menu "$title" 18 72 10 "${menu_args[@]}" </dev/tty 2>/dev/tty) || return 1
    ui_reset_screen
    [ "$mark_latest" -eq 1 ] && [ "$choice" = "1" ] && TELEMT_VERSION_HINT="★ latest"
    printf '%s' "${items[$((choice - 1))]}"
    return 0
  fi

  echo ""
  echo -e "${BOLD}${title}${NC}"
  for i in "${!items[@]}"; do
    tag="${items[$i]}"
    label="$tag"
    [ "$i" -eq 0 ] && label="${tag} ★ latest"
    [ -n "$preselect" ] && [ "$tag" = "$preselect" ] && label="${label} (из флага)"
    echo "  $((i + 1))) ${label}"
  done

  while true; do
    prompt_line choice "Выбор [1-${count}]" "1"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      [ "$mark_latest" -eq 1 ] && [ "$choice" = "1" ] && TELEMT_VERSION_HINT="★ latest"
      printf '%s' "${items[$((choice - 1))]}"
      return 0
    fi
    log_warn "Введите число от 1 до ${count}"
  done
}

pick_telemt_version() {
  local -a versions=()
  local selected preselect="${TELEMT_VERSION:-}"
  TELEMT_VERSION_HINT=""
  mapfile -t versions < <(fetch_telemt_release_versions)
  log_info "Выбор версии telemt..."
  selected=$(_pick_version_from_list "Версия telemt" "$preselect" 1 "${versions[@]}") \
    || die "Выбор версии telemt отменён"
  require_valid_telemt_version "$selected"
  TELEMT_VERSION="$selected"
  export TELEMT_VERSION
  log_ok "telemt: $(hl_telemt_version "$TELEMT_VERSION" "${TELEMT_VERSION_HINT:-}")"
}

pick_meko_type() {
  local choice="" preselect=""
  [ "${MEKO_FULL:-0}" -eq 1 ] && preselect="2"

  if has_dialog && has_tty; then
    choice=$(dialog --clear --stdout --backtitle "telemt-deploy" \
      --menu "Тип MEKO" 14 72 6 \
      1 "inline SYN FIX (iptables)" \
      2 "MEKO Launcher full (mekopr)" </dev/tty 2>/dev/tty) || die "Выбор типа MEKO отменён"
    ui_reset_screen
  else
    echo ""
    echo -e "${BOLD}Тип MEKO${NC}"
    echo "  1) inline SYN FIX (iptables)"
    echo "  2) MEKO Launcher full (mekopr)"
    prompt_line choice "Выбор [1/2]" "${preselect:-1}"
    case "$choice" in
      1|inline) choice=1 ;;
      2|full|meko) choice=2 ;;
      *) die "Неверный выбор типа MEKO" ;;
    esac
  fi

  case "$choice" in
    1) MEKO_FULL=0 ;;
    2) MEKO_FULL=1 ;;
    *) die "Неверный выбор типа MEKO" ;;
  esac
  export MEKO_FULL
}

pick_meko_version() {
  local -a versions=()
  local selected preselect="${MEKO_VERSION:-}"
  mapfile -t versions < <(fetch_meko_release_versions)
  log_info "Выбор версии MEKO..."
  selected=$(_pick_version_from_list "Версия MEKO" "$preselect" 0 "${versions[@]}") \
    || die "Выбор версии MEKO отменён"
  require_valid_meko_version "$selected"
  MEKO_VERSION="$selected"
  export MEKO_VERSION
  local mode="inline SYN FIX"
  [ "${MEKO_FULL:-0}" -eq 1 ] && mode="MEKO Launcher (full)"
  log_ok "MEKO: $(hl_meko "$mode" "$MEKO_VERSION")"
}

prepare_install_options() {
  require_tty_for_picker
  echo ""
  log_info "Подготовка параметров установки"
  echo -e "  Домен: $(hl_domain "$DOMAIN")"
  pick_telemt_version
  pick_meko_type
  pick_meko_version
  prompt_ad_tag_colored
  print_install_summary
  confirm_action "Начать установку?" || die "Установка отменена"
}
