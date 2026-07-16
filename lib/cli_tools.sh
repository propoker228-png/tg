#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLI_TOOLS_SH_VERSION="1.0"
TG_BIN="/usr/local/bin/tg"
DEPLOY_CONF="/etc/telemt-deploy.conf"

install_deploy_conf() {
  cat > "$DEPLOY_CONF" <<EOF
DEPLOY_ROOT=$DEPLOY_ROOT
EOF
  chmod 644 "$DEPLOY_CONF"
}

install_tg_command() {
  local tmp
  tmp="$(mktemp)"
  sed "s|@DEPLOY_ROOT@|$DEPLOY_ROOT|g" "$DEPLOY_ROOT/templates/tg" > "$tmp"
  install -m 0755 "$tmp" "$TG_BIN"
  rm -f "$tmp"
  install_deploy_conf
  log_ok "Команда tg установлена: $TG_BIN"
}

remove_tg_command() {
  rm -f "$TG_BIN" "$DEPLOY_CONF"
}
