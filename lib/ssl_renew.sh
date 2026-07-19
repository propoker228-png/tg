#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SSL_RENEW_SH_VERSION="1.0"
SSL_RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/telemt-deploy.sh"

ssl_install_renew_hook() {
  mkdir -p "$(dirname "$SSL_RENEW_HOOK")"
  cat > "$SSL_RENEW_HOOK" <<'EOF'
#!/bin/bash
systemctl reload nginx
systemctl restart telemt
EOF
  chmod 755 "$SSL_RENEW_HOOK"
  log_ok "Хук автообновления SSL установлен: $SSL_RENEW_HOOK"
}

ssl_renew_hook_installed() {
  [ -x "$SSL_RENEW_HOOK" ]
}

ssl_cert_days_left() {
  local domain="${1:-${DOMAIN:-}}" cert end epoch now
  cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  if [ ! -f "$cert" ]; then
    echo "-1"
    return 0
  fi
  end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2-)
  [ -n "$end" ] || { echo "-1"; return 0; }
  epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$epoch" -le 0 ]; then
    echo "-1"
    return 0
  fi
  echo $(( (epoch - now) / 86400 ))
}
