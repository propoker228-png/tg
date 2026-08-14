#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ZAPRET2_SH_VERSION="1.0"
ZAPRET2_RELEASE_VERSION="v1.0.3"
ZAPRET2_DIR="/opt/tg-zapret2"
ZAPRET2_ETC_DIR="/etc/tg-zapret2"
ZAPRET2_SERVICE="tg-zapret2.service"
ZAPRET2_START_SCRIPT="/usr/local/sbin/tg-zapret2-start.sh"
ZAPRET2_NFT_TABLE="TgDeployZ2"
ZAPRET2_QNUM="${ZAPRET2_QNUM:-200}"
ZAPRET2_SYSCTL_FILE="/etc/sysctl.d/99-tg-zapret2.conf"
ZAPRET2_WSCALE_FILE="/etc/sysctl.d/99-tg-zapret2-wscale.conf"

zapret2_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-x86_64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) die "Неподдерживаемая архитектура для zapret2: $(uname -m)" ;;
  esac
}

zapret2_is_installed() {
  [ -x "${ZAPRET2_DIR}/bin/nfqws2" ] && [ -f "$ZAPRET2_START_SCRIPT" ]
}

zapret2_service_active() {
  systemctl is-active --quiet "$ZAPRET2_SERVICE" 2>/dev/null
}

zapret2_pick_free_qnum() {
  local qnum="${ZAPRET2_QNUM}"
  if [ -f /proc/net/netfilter/nfnetlink_queue ]; then
    while grep -qE "[[:space:]]${qnum}[[:space:]]" /proc/net/netfilter/nfnetlink_queue 2>/dev/null; do
      qnum=$((qnum + 1))
      [ "$qnum" -lt 300 ] || die "Не найден свободный номер NFQUEUE"
    done
  fi
  ZAPRET2_QNUM="$qnum"
  export ZAPRET2_QNUM
}

zapret2_ensure_packages() {
  ensure_packages nftables
  modprobe nfnetlink_queue 2>/dev/null || log_warn "nfnetlink_queue не загружен"
}

zapret2_download_binary() {
  local arch tmp root lua_dir path
  arch="$(zapret2_arch)"
  tmp="$(mktemp -d)"
  curl -fsSL --max-time 120 -o "${tmp}/zapret2.tar.gz" \
    "https://github.com/bol-van/zapret2/releases/download/${ZAPRET2_RELEASE_VERSION}/zapret2-${ZAPRET2_RELEASE_VERSION}.tar.gz" \
    || die "Не удалось скачать zapret2 ${ZAPRET2_RELEASE_VERSION}"

  tar xzf "${tmp}/zapret2.tar.gz" -C "$tmp"
  root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$root" ] || die "Неверная структура архива zapret2"

  mkdir -p "${ZAPRET2_DIR}/bin" "${ZAPRET2_DIR}/lua" "$ZAPRET2_ETC_DIR"
  cp -f "${root}/binaries/${arch}/nfqws2" "${ZAPRET2_DIR}/bin/"
  chmod +x "${ZAPRET2_DIR}/bin/nfqws2"

  lua_dir=""
  for path in "${root}/nfq2/lua" "${root}/lua" "${root}/nfq/lua"; do
    if [ -f "${path}/zapret-lib.lua" ] || ls "${path}"/zapret-lib.lua* >/dev/null 2>&1; then
      lua_dir="$path"
      break
    fi
  done
  [ -n "$lua_dir" ] || die "Lua-библиотеки zapret2 не найдены в архиве"
  cp -f "${lua_dir}"/zapret-lib.lua* "${ZAPRET2_DIR}/lua/"
  cp -f "${lua_dir}"/zapret-antidpi.lua* "${ZAPRET2_DIR}/lua/"
  cp -f "$DEPLOY_ROOT/templates/zapret2/mtproto.lua" "${ZAPRET2_DIR}/lua/mtproto.lua"
  rm -rf "$tmp"
  "${ZAPRET2_DIR}/bin/nfqws2" --version >/dev/null 2>&1 || log_warn "nfqws2 --version не ответил"
}

zapret2_write_configs() {
  local port="${PROXY_PORT:-443}"
  export ZAPRET2_DIR ZAPRET2_ETC_DIR ZAPRET2_NFT_TABLE ZAPRET2_QNUM PROXY_PORT="$port"
  envsubst '${ZAPRET2_QNUM} ${ZAPRET2_DIR} ${PROXY_PORT}' \
    < "$DEPLOY_ROOT/templates/zapret2/mtproto.conf.tpl" \
    > "${ZAPRET2_ETC_DIR}/mtproto.conf"
  envsubst '${ZAPRET2_NFT_TABLE} ${ZAPRET2_DIR} ${ZAPRET2_ETC_DIR} ${ZAPRET2_QNUM} ${PROXY_PORT}' \
    < "$DEPLOY_ROOT/templates/zapret2/tg-zapret2-start.sh.tpl" \
    > "$ZAPRET2_START_SCRIPT"
  chmod +x "$ZAPRET2_START_SCRIPT"
  cp "$DEPLOY_ROOT/templates/zapret2/tg-zapret2.service" \
    "/etc/systemd/system/${ZAPRET2_SERVICE}"
}

zapret2_apply_sysctl() {
  cat > "$ZAPRET2_SYSCTL_FILE" <<'EOF'
net.ipv4.tcp_tw_reuse = 1
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$ZAPRET2_SYSCTL_FILE" >/dev/null 2>&1 || true
}

zapret2_maybe_apply_wscale() {
  local sample
  sample="$(ss -tin '( sport = :'"${PROXY_PORT:-443}"' )' 2>/dev/null | grep -o 'wscale:[0-9]*' | head -1 | cut -d: -f2)"
  [ -n "$sample" ] && [ "$sample" -ge 11 ] 2>/dev/null || return 0
  log_warn "wscale=${sample} — применяем оптимизацию TCP-буфера для zapret2"
  cat > "$ZAPRET2_WSCALE_FILE" <<'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
EOF
  sysctl --system >/dev/null 2>&1 || true
}

zapret2_install() {
  zapret2_ensure_packages
  zapret2_pick_free_qnum
  zapret2_download_binary
  zapret2_write_configs
  zapret2_apply_sysctl
  zapret2_maybe_apply_wscale
  systemctl daemon-reload
  systemctl enable "$ZAPRET2_SERVICE"
  systemctl restart "$ZAPRET2_SERVICE"
  sleep 1
  zapret2_service_active || die "Служба $ZAPRET2_SERVICE не запустилась — проверьте: journalctl -u $ZAPRET2_SERVICE -n 30"
  log_ok "Zapret2 MTProto fix установлен (порт ${PROXY_PORT:-443}, NFQUEUE ${ZAPRET2_QNUM})"
}

zapret2_remove() {
  systemctl stop "$ZAPRET2_SERVICE" 2>/dev/null || true
  systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${ZAPRET2_SERVICE}" "$ZAPRET2_START_SCRIPT"
  nft delete table ip "$ZAPRET2_NFT_TABLE" 2>/dev/null || true
  rm -rf "$ZAPRET2_DIR" "$ZAPRET2_ETC_DIR"
  rm -f "$ZAPRET2_SYSCTL_FILE" "$ZAPRET2_WSCALE_FILE"
  systemctl daemon-reload 2>/dev/null || true
}

zapret2_status_label() {
  if zapret2_service_active; then
    echo "active"
  elif zapret2_is_installed; then
    echo "inactive"
  else
    echo "not installed"
  fi
}
