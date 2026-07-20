#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

resolve_telemt_version() {
  if [ -n "${TELEMT_VERSION:-}" ]; then
    require_valid_telemt_version "$TELEMT_VERSION"
    echo "$TELEMT_VERSION"
    return
  fi
  local latest
  latest=$(curl -fsSL -H "User-Agent: telemt-deploy" \
    https://api.github.com/repos/telemt/telemt/releases/latest \
    | jq -r .tag_name | sed 's/^v//')
  [ -n "$latest" ] && [ "$latest" != "null" ] || die "Не удалось получить latest версию telemt"
  require_valid_telemt_version "$latest"
  echo "$latest"
}

telemt_install_binary() {
  local version="$1"
  require_valid_telemt_version "$version"
  local url="https://github.com/telemt/telemt/releases/download/${version}/telemt-x86_64-linux-gnu.tar.gz"
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp"
  install -m 0755 "$tmp/telemt" /bin/telemt
  rm -rf "$tmp"
  /bin/telemt --version
}

telemt_write_config() {
  if [ -n "${AD_TAG:-}" ]; then
    require_valid_ad_tag "$AD_TAG"
    export AD_TAG_LINE="ad_tag = \"${AD_TAG}\""
  else
    export AD_TAG_LINE=""
  fi
  if [ "${CLUSTER_ROLE:-}" = "node" ] && [ -n "${CLUSTER_DOMAIN:-}" ]; then
    export PUBLIC_HOST="$CLUSTER_DOMAIN"
    export TELEMT_TLS_DOMAIN="$CLUSTER_DOMAIN"
  else
    export PUBLIC_HOST="${DOMAIN}"
    export TELEMT_TLS_DOMAIN="${TLS_DOMAIN:-$DOMAIN}"
  fi
  render_template "$DEPLOY_ROOT/templates/telemt.toml.tpl" /etc/telemt/telemt.toml
  chown root:telemt /etc/telemt/telemt.toml
  chmod 640 /etc/telemt/telemt.toml
}

telemt_install_service() {
  cp "$DEPLOY_ROOT/templates/telemt.service" /etc/systemd/system/telemt.service
  systemctl daemon-reload
  systemctl enable telemt
  systemctl restart telemt
  systemctl is-active --quiet telemt || {
    journalctl -u telemt --no-pager -n 20
    die "telemt не запустился"
  }
  if ! wait_telemt_port_443 30; then
    journalctl -u telemt --no-pager -n 20
    log_warn "telemt active, но порт 443 ещё не слушается — проверка повторится позже"
  fi
  log_ok "telemt запущен"
}

telemt_generate_secret() {
  if [ -f "$SECRET_FILE" ]; then
    SECRET=$(cat "$SECRET_FILE")
    log_info "Используем существующий секрет из $SECRET_FILE"
  else
    SECRET=$(openssl rand -hex 16)
    echo "$SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
  fi
  export SECRET
}

telemt_install() {
  telemt_generate_secret
  local version
  version=$(resolve_telemt_version)
  log_info "Установка telemt $version"
  telemt_install_binary "$version"
  telemt_write_config
  telemt_install_service
}
