#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Публичные DNS — как видят клиенты и Let's Encrypt (не локальный DNS хостинга).
DNS_CHECK_SERVERS=(8.8.8.8 1.1.1.1)

lookup_domain_a() {
  local domain="$1" server ip=""
  for server in "${DNS_CHECK_SERVERS[@]}"; do
    ip=$(dig +short +time=3 +tries=1 A "$domain" @"$server" 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# check_domain_dns — проверка без выхода из скрипта
# 0 = OK, 1 = нет A-записи, 2 = A-запись не указывает на этот сервер
check_domain_dns() {
  local domain="$1"
  local server_ip dns_ip

  server_ip=$(get_public_ip)
  dns_ip=$(lookup_domain_a "$domain" || true)

  if [ -z "$dns_ip" ]; then
    log_err "DNS: домен $domain не резолвится (нет A-записи)"
    return 1
  fi

  if [ "$dns_ip" = "$server_ip" ]; then
    log_ok "DNS OK: $domain → $server_ip"
    return 0
  fi

  log_warn "DNS: $domain → $dns_ip, сервер → $server_ip (не совпадают)"
  return 2
}

validate_domain_dns() {
  local domain="$1" rc
  check_domain_dns "$domain"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) die "DNS: домен $domain не резолвится (нет A-записи)" ;;
    2)
      if is_auto_mode; then
        die "DNS не указывает на этот сервер"
      fi
      confirm_yes "DNS не указывает на этот сервер. Продолжить установку?" \
        || die "Установка отменена пользователем"
      return 0
      ;;
  esac
}

prompt_domain_dns_retry_or_exit() {
  local dns_choice=""
  while true; do
    echo ""
    echo -e "  ${BOLD}DNS-проверка не пройдена${NC}"
    echo "  1) Ввести домен повторно"
    echo "  0) Выход"
    prompt_line dns_choice "Выбор" ""
    case "$dns_choice" in
      1|retry|повтор) return 0 ;;
      0|q|Q|exit|выход) return 1 ;;
      *) log_warn "Введите 1 или 0" ;;
    esac
  done
}

