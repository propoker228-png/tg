#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PANEL_SH_VERSION="1.0"
PANEL_CREDENTIALS_FILE="/etc/telemt-deploy.panel"
PANEL_STATIC_DIR="/opt/telemt-panel"
PANEL_SSL_DIR="/etc/telemt-panel"
PANEL_API_PORT="${PANEL_API_PORT:-19091}"
PANEL_NGINX_SITE="/etc/nginx/sites-available/telemt-panel"
PANEL_NGINX_ENABLED="/etc/nginx/sites-enabled/telemt-panel"
PANEL_METRICS_DIR="/var/lib/telemt-deploy/metrics"

panel_generate_credentials() {
  PANEL_USER="${PANEL_USER:-admin}"
  PANEL_PASS="${PANEL_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
  cat > "$PANEL_CREDENTIALS_FILE" <<EOF
PANEL_USER=$PANEL_USER
PANEL_PASS=$PANEL_PASS
EOF
  chmod 600 "$PANEL_CREDENTIALS_FILE"
  export PANEL_USER PANEL_PASS
}

panel_show_access_info() {
  local ip
  ip=$(get_public_ip 2>/dev/null || echo "127.0.0.1")
  # shellcheck disable=SC1090
  [ -f "$PANEL_CREDENTIALS_FILE" ] && source "$PANEL_CREDENTIALS_FILE"
  echo ""
  echo -e "${BOLD}Панель кластера:${NC}"
  echo -e "  URL:   ${CYAN}https://${ip}:8443/${NC}"
  echo -e "  Логин: ${PANEL_USER:-admin}"
  echo -e "  Пароль: ${PANEL_PASS:-(см. ${PANEL_CREDENTIALS_FILE})}"
  echo ""
}

panel_install_nginx_site() {
  local cert key
  cert="${PANEL_SSL_DIR}/cert.pem"
  key="${PANEL_SSL_DIR}/key.pem"
  export PANEL_SSL_CERT="$cert"
  export PANEL_SSL_KEY="$key"
  export PANEL_STATIC_DIR PANEL_API_PORT
  envsubst '${PANEL_SSL_CERT} ${PANEL_SSL_KEY} ${PANEL_STATIC_DIR} ${PANEL_API_PORT}' \
    < "$DEPLOY_ROOT/templates/nginx-panel.tpl" > "$PANEL_NGINX_SITE"
  ln -sf "$PANEL_NGINX_SITE" "$PANEL_NGINX_ENABLED"
}

panel_install_systemd() {
  local unit="/etc/systemd/system/telemt-panel.service"
  sed "s|@DEPLOY_ROOT@|$DEPLOY_ROOT|g" \
    < "$DEPLOY_ROOT/templates/telemt-panel.service" > "$unit"
  systemctl daemon-reload
  systemctl enable telemt-panel.service
  systemctl restart telemt-panel.service
}

panel_install() {
  if ! command -v nginx >/dev/null 2>&1; then
    log_info "Установка nginx для панели..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 обязателен для панели кластера"
  fi

  mkdir -p "$PANEL_STATIC_DIR" "$PANEL_SSL_DIR" "$PANEL_METRICS_DIR"
  chmod 755 "$PANEL_STATIC_DIR"
  chmod 700 "$PANEL_SSL_DIR"
  chmod 755 "$PANEL_METRICS_DIR"

  if [ ! -f "${PANEL_SSL_DIR}/cert.pem" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "${PANEL_SSL_DIR}/key.pem" \
      -out "${PANEL_SSL_DIR}/cert.pem" \
      -subj "/CN=telemt-panel" 2>/dev/null
    chmod 600 "${PANEL_SSL_DIR}/key.pem"
  fi

  cp "$DEPLOY_ROOT/templates/panel/index.html" "$PANEL_STATIC_DIR/index.html"
  panel_install_nginx_site
  panel_install_systemd

  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  else
    log_warn "nginx -t не прошёл — проверьте конфиг панели"
  fi

  ufw allow 8443/tcp comment 'telemt-deploy cluster panel' 2>/dev/null || true
  log_ok "Панель кластера установлена (порт 8443)"
}
