#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_FLOW_SH_VERSION="1.2"

run_install_flow() {
  [ -n "${DOMAIN:-}" ] || die "Адрес подключения не задан"
  if install_is_ip_only; then
    [ -n "${TLS_DOMAIN:-}" ] || die "Домен маскировки (TLS_DOMAIN) обязателен в режиме без своего домена"
    is_valid_ipv4 "$DOMAIN" || die "В режиме IP-only DOMAIN должен быть IPv4-адресом сервера"
    require_valid_domain_name "$TLS_DOMAIN"
  else
    TLS_DOMAIN="${TLS_DOMAIN:-$DOMAIN}"
  fi
  export DOMAIN TLS_DOMAIN INSTALL_IP_ONLY

  if install_is_ip_only; then
    log_info "Старт установки: подключение по IP $(hl_domain "$DOMAIN"), маскировка $(hl_domain "$TLS_DOMAIN")"
  else
    log_info "Старт установки для $(hl_domain "$DOMAIN")"
    if [ "$TLS_DOMAIN" != "$DOMAIN" ]; then
      log_info "Маскировка TLS (SNI): $(hl_domain "$TLS_DOMAIN")"
    fi
  fi

  prereq_install
  if install_is_ip_only; then
    ssl_install_self_signed "$TLS_DOMAIN"
    nginx_install_production
  else
    nginx_install_temp
    ssl_obtain_cert "$DOMAIN"
    ssl_install_renew_hook
    nginx_install_production
  fi
  telemt_install
  meko_install
  firewall_setup
  verify_install "$DOMAIN" || log_warn "Проверка выявила проблемы, продолжаем handoff"

  show_mtproxybot_handoff "$DOMAIN"

  if [ -n "${AD_TAG:-}" ]; then
    systemctl restart telemt
    wait_telemt_port_443 30 || log_warn "telemt перезапущен, ожидание порта 443 продолжается"
    verify_install "$DOMAIN" || log_warn "Проверка после применения ad_tag выявила проблемы"
  fi

  save_state
  install_tg_command
  meko_upgrade_if_needed
  show_proxy_online_stats
  log_ok "Установка завершена"
  log_info "Меню управления: tg"
}

prepare_install_domain() {
  local dns_rc mode=""

  if port_in_use 443 && ! telemt_listens_443; then
    die "Порт 443 занят другим процессом. Освободите: ss -tlnp | grep 443"
  fi

  if [ "${INSTALL_IP_ONLY:-0}" -eq 1 ]; then
    DOMAIN="$(get_public_ip)"
    export DOMAIN INSTALL_IP_ONLY
    log_ok "Режим без своего домена: подключение по IP ${DOMAIN}"
    return 0
  fi

  if [ -n "${DOMAIN:-}" ]; then
    DOMAIN="$(require_valid_domain_name "$DOMAIN")"
    export DOMAIN
    while true; do
      check_domain_dns "$DOMAIN"
      dns_rc=$?
      case "$dns_rc" in
        0) return 0 ;;
        1)
          if is_auto_mode; then
            die "DNS: домен $DOMAIN не резолвится (нет A-записи)"
          fi
          if ! prompt_domain_dns_retry_or_exit; then
            die "Установка отменена"
          fi
          prompt_line DOMAIN "Домен (A-запись → этот сервер)" ""
          [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
          DOMAIN="$(require_valid_domain_name "$DOMAIN")"
          export DOMAIN
          ;;
        2)
          if is_auto_mode; then
            die "DNS не указывает на этот сервер"
          fi
          if confirm_yes "DNS не указывает на этот сервер. Продолжить установку?"; then
            return 0
          fi
          prompt_line DOMAIN "Домен (A-запись → этот сервер)" ""
          [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
          DOMAIN="$(require_valid_domain_name "$DOMAIN")"
          export DOMAIN
          ;;
      esac
    done
  fi

  if is_auto_mode; then
    die "Укажите --domain или --ip-only с --tls-domain"
  fi

  while true; do
    echo ""
    echo -e "${BOLD}Способ подключения клиентов${NC}"
    echo "  1) Свой домен (A-запись → этот сервер)"
    echo "  2) Только IP сервера (без своего домена и SSL от Let's Encrypt)"
    prompt_line mode "Выбор [1/2]" "1"
    case "$mode" in
      1|domain)
        INSTALL_IP_ONLY=0
        export INSTALL_IP_ONLY
        break
        ;;
      2|ip|ip-only)
        INSTALL_IP_ONLY=1
        DOMAIN="$(get_public_ip)"
        export DOMAIN INSTALL_IP_ONLY
        log_ok "Подключение по IP: ${DOMAIN}"
        return 0
        ;;
      *)
        log_warn "Введите 1 или 2"
        ;;
    esac
  done

  while true; do
    prompt_line DOMAIN "Домен (A-запись → этот сервер)" ""
    [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
    DOMAIN="$(require_valid_domain_name "$DOMAIN")"
    export DOMAIN

    check_domain_dns "$DOMAIN"
    dns_rc=$?
    case "$dns_rc" in
      0) break ;;
      1)
        if ! prompt_domain_dns_retry_or_exit; then
          die "Установка отменена"
        fi
        DOMAIN=""
        ;;
      2)
        if confirm_yes "DNS не указывает на этот сервер. Продолжить установку?"; then
          break
        fi
        DOMAIN=""
        ;;
    esac
  done

  if ! is_auto_mode; then
    confirm_action "Начать установку для домена ${DOMAIN}?" || die "Установка отменена"
  fi
}
