#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"

DOCTOR_SH_VERSION="1.0"

DOCTOR_TOTAL=0
DOCTOR_FAILED=0

doctor_reset() {
  DOCTOR_TOTAL=0
  DOCTOR_FAILED=0
}

doctor_record() {
  local name="$1" status="$2" detail="${3:-}"
  DOCTOR_TOTAL=$((DOCTOR_TOTAL + 1))
  case "$status" in
    pass|ok)
      log_ok "$name${detail:+ — $detail}"
      ;;
    warn)
      log_warn "$name${detail:+ — $detail}"
      ;;
    *)
      log_err "$name${detail:+ — $detail}"
      DOCTOR_FAILED=$((DOCTOR_FAILED + 1))
      ;;
  esac
}

doctor_check_dns() {
  local domain="$1" server_ip dns_ip
  if install_is_ip_only || is_valid_ipv4 "$domain"; then
    doctor_record "DNS" pass "режим IP, проверка пропущена"
    return
  fi
  server_ip=$(get_public_ip)
  dns_ip=$(lookup_domain_a "$domain" 2>/dev/null || true)
  if [ -z "$dns_ip" ]; then
    doctor_record "DNS" fail "нет A-записи для $domain"
    return
  fi
  if [ "$dns_ip" = "$server_ip" ]; then
    doctor_record "DNS" pass "$domain → $server_ip"
  else
    doctor_record "DNS" warn "$domain → $dns_ip (сервер $server_ip)"
  fi
}

doctor_check_rkn() {
  if check_rkn_ip "$(get_public_ip)" >/dev/null 2>&1; then
    doctor_record "РКН IP" pass "не в реестре"
  else
    local rc=$?
    if [ "$rc" -eq 1 ]; then
      doctor_record "РКН IP" fail "IP в реестре заблокированных"
    else
      doctor_record "РКН IP" warn "не удалось проверить"
    fi
  fi
}

doctor_check_ssl() {
  local domain="$1" days
  if install_is_ip_only; then
    if [ -f /etc/telemt/selfsigned/fullchain.pem ]; then
      doctor_record "SSL" pass "self-signed (режим IP)"
    else
      doctor_record "SSL" fail "self-signed сертификат не найден"
    fi
    return
  fi
  days=$(ssl_cert_days_left "$domain")
  if [ "$days" -lt 0 ]; then
    doctor_record "SSL" fail "сертификат не найден"
    return
  fi
  if [ "$days" -lt 14 ]; then
    doctor_record "SSL" warn "истекает через ${days} дн."
    return
  fi
  doctor_record "SSL" pass "действителен ещё ${days} дн."
}

doctor_check_sni() {
  local sni rc
  sni=$(telemt_tls_domain)
  check_sni_local "$sni"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    doctor_record "SNI/TLS (локально)" pass "handshake OK (SNI=$sni)"
  elif [ "$rc" -eq 2 ]; then
    doctor_record "SNI/TLS (локально)" warn "openssl/SNI недоступны"
  else
    doctor_record "SNI/TLS (локально)" fail "handshake failed (SNI=$sni)"
  fi
  echo -e "  ${GRAY}Для DPI в РФ: @Sni_checker_bot${NC}"
}

doctor_print_summary() {
  local passed=$((DOCTOR_TOTAL - DOCTOR_FAILED))
  echo ""
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  if [ "$DOCTOR_FAILED" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ✅ ${passed}/${DOCTOR_TOTAL} проверок пройдено${NC}"
  else
    echo -e "${YELLOW}${BOLD}  ⚠️  ${passed}/${DOCTOR_TOTAL} пройдено, ошибок: ${DOCTOR_FAILED}${NC}"
  fi
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo ""
  return "$DOCTOR_FAILED"
}

run_doctor_full() {
  local domain="$1" link="" code sni_mode
  env_load_settings 2>/dev/null || true
  [ -n "$domain" ] || domain="${DOMAIN:-}"
  [ -n "$domain" ] || die "Домен не задан"

  doctor_reset
  echo ""
  echo -e "${BOLD}=== Диагностика (doctor) — ${domain} ===${NC}"
  echo ""

  doctor_check_dns "$domain"

  set +e
  check_rkn_ip "$(get_public_ip)" >/dev/null 2>&1
  case $? in
    0) doctor_record "РКН IP" pass "не в реестре" ;;
    1) doctor_record "РКН IP" fail "IP в реестре" ;;
    *) doctor_record "РКН IP" warn "проверка недоступна" ;;
  esac
  set -e

  for svc in telemt nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      doctor_record "Сервис $svc" pass "active"
    else
      doctor_record "Сервис $svc" fail "не active"
    fi
  done

  sni_mode=$(meko_install_mode 2>/dev/null || echo none)
  if [ "$sni_mode" = "inline" ] || [ "$sni_mode" = "full" ]; then
    if systemctl is-active --quiet mtpr-synfix 2>/dev/null; then
      doctor_record "MEKO mtpr-synfix" pass "active (v$(meko_installed_version 2>/dev/null || echo ?))"
    else
      doctor_record "MEKO mtpr-synfix" fail "не active"
    fi
  else
    doctor_record "MEKO" warn "не установлен"
  fi

  if telemt_listens_443; then
    doctor_record "Порт 443" pass "telemt слушает"
  else
    doctor_record "Порт 443" fail "telemt не слушает 443"
  fi

  code=$(wait_mask_site_http "$(telemt_mask_domain)" 200 10 || echo "000")
  if [ "$code" = "200" ]; then
    doctor_record "Mask-site" pass "HTTP 200"
  else
    doctor_record "Mask-site" fail "HTTP $code"
  fi

  if link=$(fetch_proxy_link 2>/dev/null); then
    doctor_record "Ссылка API" pass "$link"
    export PROXY_LINK="$link"
  else
    doctor_record "Ссылка API" fail "API недоступен"
  fi

  doctor_check_ssl "$domain"
  doctor_check_sni

  if ssl_renew_hook_installed; then
    doctor_record "SSL auto-renew" pass "хук установлен"
  else
    doctor_record "SSL auto-renew" warn "хук не найден"
  fi

  doctor_print_summary
  return "$DOCTOR_FAILED"
}
