#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=stub_site.sh
source "$(dirname "${BASH_SOURCE[0]}")/stub_site.sh"

nginx_deploy_stub_site() {
  deploy_stub_site
}

nginx_install_temp() {
  render_template "$DEPLOY_ROOT/templates/nginx-acme-temp.tpl" \
    /etc/nginx/sites-available/telemt-acme-temp
  ln -sf /etc/nginx/sites-available/telemt-acme-temp /etc/nginx/sites-enabled/telemt-acme-temp
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

nginx_disable_conflicting_sites() {
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/telemt-acme-temp
}

nginx_install_production() {
  nginx_deploy_stub_site
  nginx_disable_conflicting_sites
  if install_is_ip_only; then
    export SSL_CERT_PATH SSL_KEY_PATH
    SSL_CERT_PATH="$(ssl_cert_path)"
    SSL_KEY_PATH="$(ssl_key_path)"
    render_template "$DEPLOY_ROOT/templates/nginx-site-iponly.tpl" \
      /etc/nginx/sites-available/telemt-site
  else
    render_template "$DEPLOY_ROOT/templates/nginx-site.tpl" \
      /etc/nginx/sites-available/telemt-site
  fi
  ln -sf /etc/nginx/sites-available/telemt-site /etc/nginx/sites-enabled/telemt-site
  nginx_disable_conflicting_sites
  nginx -t
  systemctl restart nginx
  log_ok "nginx self-mask настроен"
}
