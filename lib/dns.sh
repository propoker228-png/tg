#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

validate_domain_dns() {
  local domain="$1"
  local server_ip dns_ip

  server_ip=$(get_public_ip)
  dns_ip=$(dig +short A "$domain" | tail -1)

  [ -n "$dns_ip" ] || die "DNS: домен $domain не резолвится (нет A-записи)"

  if [ "$dns_ip" = "$server_ip" ]; then
    log_ok "DNS OK: $domain → $server_ip"
    return 0
  fi

  log_warn "DNS: $domain → $dns_ip, сервер → $server_ip (не совпадают)"
  if is_auto_mode; then
    die "DNS не указывает на этот сервер"
  fi
  confirm_yes "DNS не указывает на этот сервер. Продолжить установку?" \
    || die "Установка отменена пользователем"
}
