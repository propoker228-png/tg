#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ssl_obtain_cert() {
  local domain="$1"
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"

  if [ -f "$cert" ]; then
    log_info "Сертификат уже существует для $domain, пропускаем certbot"
    return 0
  fi

  certbot certonly --webroot -w /var/www/html \
    -d "$domain" --non-interactive --agree-tos \
    --register-unsafely-without-email --cert-name "$domain" \
    || die "certbot не смог выдать сертификат. Проверьте DNS и порт 80."

  log_ok "Сертификат получен: $cert"
}
