#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

nginx_install_temp() {
  render_template "$DEPLOY_ROOT/templates/nginx-acme-temp.tpl" \
    /etc/nginx/sites-available/telemt-acme-temp
  ln -sf /etc/nginx/sites-available/telemt-acme-temp /etc/nginx/sites-enabled/telemt-acme-temp
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

nginx_install_production() {
  cp "$DEPLOY_ROOT/templates/index.html" /var/www/html/index.html
  render_template "$DEPLOY_ROOT/templates/nginx-site.tpl" \
    /etc/nginx/sites-available/telemt-site
  ln -sf /etc/nginx/sites-available/telemt-site /etc/nginx/sites-enabled/telemt-site
  rm -f /etc/nginx/sites-enabled/telemt-acme-temp
  nginx -t
  systemctl restart nginx
  log_ok "nginx self-mask настроен"
}
