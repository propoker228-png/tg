#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SSL_SH_VERSION="1.1"
SSL_SELF_SIGNED_DIR="/etc/telemt/selfsigned"

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

ssl_install_self_signed() {
  local cn="$1" san
  [ -n "$cn" ] || die "Имя для self-signed сертификата не задано"
  mkdir -p "$SSL_SELF_SIGNED_DIR"
  san="DNS:${cn}"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${SSL_SELF_SIGNED_DIR}/privkey.pem" \
    -out "${SSL_SELF_SIGNED_DIR}/fullchain.pem" \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=${san}" 2>/dev/null \
    || openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "${SSL_SELF_SIGNED_DIR}/privkey.pem" \
      -out "${SSL_SELF_SIGNED_DIR}/fullchain.pem" \
      -subj "/CN=${cn}"
  chmod 600 "${SSL_SELF_SIGNED_DIR}/privkey.pem"
  chmod 644 "${SSL_SELF_SIGNED_DIR}/fullchain.pem"
  log_ok "Self-signed сертификат для маскировки (${cn})"
}

ssl_cert_path() {
  if install_is_ip_only; then
    printf '%s/fullchain.pem' "$SSL_SELF_SIGNED_DIR"
  else
    printf '/etc/letsencrypt/live/%s/fullchain.pem' "${DOMAIN}"
  fi
}

ssl_key_path() {
  if install_is_ip_only; then
    printf '%s/privkey.pem' "$SSL_SELF_SIGNED_DIR"
  else
    printf '/etc/letsencrypt/live/%s/privkey.pem' "${DOMAIN}"
  fi
}
