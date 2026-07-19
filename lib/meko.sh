#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MEKO_SH_VERSION="1.3"
MEKO_SYNFIX_VERSION="3.0.1"
MEKO_VERSION_FILE="/opt/mtpr-simple/version"
MEKO_APPLY_SCRIPT="/opt/mtpr-simple/apply-mtpr-synfix.sh"
MEKO_RAW_BASE="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO"

meko_bundled_version() {
  echo "$MEKO_SYNFIX_VERSION"
}

meko_tag_name() {
  local version="$1"
  [[ "$version" == v* ]] && printf '%s' "$version" || printf 'v%s' "$version"
}

meko_download_inline_script() {
  local version="$1" dest="$2"
  local bundled

  bundled="$(meko_bundled_version)"
  if [ "$version" != "$bundled" ]; then
    log_warn "inline SYN FIX v${version} не публикуется отдельно — используем bundled v${bundled}"
  fi

  if [ -f "$DEPLOY_ROOT/templates/apply-mtpr-synfix.sh" ]; then
    cp "$DEPLOY_ROOT/templates/apply-mtpr-synfix.sh" "$dest"
    return 0
  fi

  local tag paths=(
    "mtpr-synfix-nft.sh"
    "proxys/mtpr-synfix-nft.sh"
    "apply-mtpr-synfix.sh"
  )
  local path url

  tag="$(meko_tag_name "$bundled")"
  for path in "${paths[@]}"; do
    url="${MEKO_RAW_BASE}/${tag}/${path}"
    if curl -fsSL --max-time 30 "$url" -o "$dest" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

meko_installed_version() {
  if [ -f "$MEKO_VERSION_FILE" ]; then
    tr -d '[:space:]' < "$MEKO_VERSION_FILE"
    return 0
  fi
  echo "н/д"
}

meko_is_inline_installed() {
  [ -f "$MEKO_APPLY_SCRIPT" ]
}

meko_is_full_installed() {
  [ -f /opt/mtpr-simple/main.sh ]
}

meko_install_mode() {
  if meko_is_full_installed; then
    echo "full"
  elif meko_is_inline_installed; then
    echo "inline"
  else
    echo "none"
  fi
}

meko_update_available() {
  local installed bundled
  [ "$(meko_install_mode)" = "inline" ] || return 1
  bundled="$(meko_bundled_version)"
  installed="$(meko_installed_version)"
  [ "$installed" != "н/д" ] || return 1
  version_gt "$bundled" "$installed"
}

meko_write_version() {
  local version="${1:-$(meko_bundled_version)}"
  mkdir -p "$(dirname "$MEKO_VERSION_FILE")"
  echo "$version" > "$MEKO_VERSION_FILE"
}

meko_install_inline_at() {
  local version="${1:-$(meko_bundled_version)}"
  require_valid_meko_version "$version"

  mkdir -p /opt/mtpr-simple
  echo "443" > /opt/mtpr-simple/port
  meko_download_inline_script "$version" /opt/mtpr-simple/apply-mtpr-synfix.sh \
    || die "Не удалось скачать MEKO inline v${version}"
  chmod +x /opt/mtpr-simple/apply-mtpr-synfix.sh
  cp "$DEPLOY_ROOT/templates/mtpr-synfix.service" /etc/systemd/system/mtpr-synfix.service
  meko_write_version "$version"
  modprobe xt_u32 2>/dev/null || log_warn "xt_u32 не загружен — MEKO может не работать"
  modprobe xt_hashlimit 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable mtpr-synfix
  systemctl restart mtpr-synfix
  log_ok "MEKO SYN FIX (inline) v${version} установлен"
}

meko_install_inline() {
  meko_install_inline_at "$(meko_bundled_version)"
}

meko_upgrade_inline() {
  local version="${MEKO_VERSION:-$(meko_bundled_version)}"
  log_info "Обновление MEKO SYN FIX до v${version}..."
  meko_install_inline_at "$version"
  log_ok "MEKO SYN FIX обновлён до v$(meko_installed_version)"
}

meko_install_full_at() {
  local version="${1:-}"
  local tag url tmp

  [ -n "$version" ] || die "Версия MEKO Launcher не задана"
  require_valid_meko_version "$version"
  tag="$(meko_tag_name "$version")"
  url="${MEKO_RAW_BASE}/${tag}/install_main.sh"
  tmp=$(mktemp)
  curl -fsSL --max-time 60 "$url" -o "$tmp" \
    || die "Не удалось скачать MEKO Launcher install_main.sh для ${tag}"
  bash "$tmp" </dev/tty 2>/dev/null || bash "$tmp" </dev/null
  rm -f "$tmp"
  echo "/etc/telemt/telemt.toml" > /opt/mtpr-simple/config_path
  if [ -f /opt/mtpr-simple/main.sh ]; then
    bash /opt/mtpr-simple/main.sh -auto_install 443 </dev/tty 2>/dev/null \
      || bash /opt/mtpr-simple/main.sh -auto_install 443 </dev/null || true
  fi
  meko_write_version "$version"
  log_ok "MEKO Launcher (mekopr) v${version} установлен"
}

meko_install_full() {
  meko_install_full_at "${MEKO_VERSION:-}"
}

meko_install() {
  local version="${MEKO_VERSION:-$(meko_bundled_version)}"
  if [ "${MEKO_FULL:-0}" -eq 1 ]; then
    meko_install_full_at "$version"
  elif meko_is_inline_installed && meko_update_available && [ -z "${MEKO_VERSION:-}" ]; then
    log_info "Найдена устаревшая версия MEKO SYN FIX v$(meko_installed_version), обновляем..."
    meko_upgrade_inline
  else
    meko_install_inline_at "$version"
  fi
}

meko_show_version_info() {
  local bundled installed status mode
  bundled="$(meko_bundled_version)"
  installed="$(meko_installed_version)"
  mode="$(meko_install_mode)"

  case "$mode" in
    inline) mode="inline SYN FIX" ;;
    full) mode="MEKO Launcher (full)" ;;
    *) mode="не установлен" ;;
  esac

  if systemctl is-active --quiet mtpr-synfix 2>/dev/null; then
    status="active"
  else
    status="inactive"
  fi

  echo "  тип: ${mode}"
  echo "  установлена: v${installed}"
  echo "  в комплекте: v${bundled}"
  echo "  статус: ${status}"
  if meko_update_available; then
    echo -e "  ${YELLOW}доступно обновление до v${bundled}${NC}"
  fi
}

meko_upgrade_if_needed() {
  if meko_update_available; then
    if is_auto_mode; then
      meko_upgrade_inline
    else
      log_warn "Доступно обновление MEKO SYN FIX: v$(meko_installed_version) -> v$(meko_bundled_version)"
      log_info "Обновите через меню (п. 7) или: sudo bash install.sh --meko-upgrade"
    fi
  fi
}
