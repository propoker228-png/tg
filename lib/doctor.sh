#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"
# shellcheck source=proxy_mode.sh
source "$(dirname "${BASH_SOURCE[0]}")/proxy_mode.sh"
# shellcheck source=meko_stats.sh
source "$(dirname "${BASH_SOURCE[0]}")/meko_stats.sh"
# shellcheck source=zapret2.sh
source "$(dirname "${BASH_SOURCE[0]}")/zapret2.sh"
# shellcheck source=syn_fix.sh
source "$(dirname "${BASH_SOURCE[0]}")/syn_fix.sh"

DOCTOR_SH_VERSION="1.1"

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

doctor_check_meko_syn_ratio() {
  local accept=0 reject=0 pct="" burst=""
  if [ "$(meko_install_mode 2>/dev/null || echo none)" = "none" ]; then
    return 0
  fi
  read -r accept reject <<< "$(meko_stats_syn_counts 2>/dev/null || echo "0 0")"
  burst="$(meko_stats_hashlimit_burst)"
  if [ "${burst:-1}" != "1" ]; then
    doctor_record "MEKO hashlimit burst" warn "burst=${burst} (рекомендуется 1 без A/B-теста)"
  fi
  if pct=$(meko_stats_accept_pct 2>/dev/null); then
    if [ "$pct" -lt 70 ]; then
      doctor_record "MEKO SYN ratio" warn "ACCEPT ${pct}% (${accept}/${accept}+${reject})"
    else
      doctor_record "MEKO SYN ratio" pass "ACCEPT ${pct}%"
    fi
  else
    doctor_record "MEKO SYN ratio" pass "нет SYN-счётчиков (ожидаемо без клиентов)"
  fi
}

doctor_check_proxy_mode() {
  if proxy_mode_is_secure && install_is_ip_only; then
    doctor_record "Режим dd" warn "IP-only — медленное подключение (~15–20 с); используйте домен"
  elif proxy_mode_is_secure; then
    doctor_record "Режим dd" pass "$(proxy_mode_label), tls_emulation=true"
  fi
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

  for svc in telemt nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      doctor_record "Сервис $svc" pass "active"
    else
      doctor_record "Сервис $svc" fail "не active"
    fi
  done

  case "${SYN_FIX_MODE:-meko}" in
    meko)
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
      ;;
    zapret2)
      if zapret2_service_active; then
        doctor_record "Zapret2 fix" pass "active (NFQUEUE ${ZAPRET2_QNUM:-200})"
      else
        doctor_record "Zapret2 fix" fail "tg-zapret2 не active"
      fi
      if nft list table ip "$ZAPRET2_NFT_TABLE" >/dev/null 2>&1; then
        doctor_record "Zapret2 NFT" pass "таблица $ZAPRET2_NFT_TABLE"
      else
        doctor_record "Zapret2 NFT" fail "таблица $ZAPRET2_NFT_TABLE отсутствует"
      fi
      ;;
    none)
      doctor_record "SYN-фикс" warn "отключён"
      ;;
  esac

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
  if syn_fix_is_meko && [ "$(meko_install_mode 2>/dev/null || echo none)" != "none" ]; then
    doctor_check_meko_syn_ratio
  fi
  doctor_check_proxy_mode

  if ssl_renew_hook_installed; then
    doctor_record "SSL auto-renew" pass "хук установлен"
  else
    doctor_record "SSL auto-renew" warn "хук не найден"
  fi

  doctor_print_summary
  return "$DOCTOR_FAILED"
}
