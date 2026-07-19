#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_FLOW_SH_VERSION="1.1"

run_install_flow() {
  [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
  export DOMAIN

  log_info "Старт установки для $(hl_domain "$DOMAIN")"

  prereq_install
  nginx_install_temp
  ssl_obtain_cert "$DOMAIN"
  ssl_install_renew_hook
  nginx_install_production
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
  local dns_rc

  if port_in_use 443 && ! telemt_listens_443; then
    die "Порт 443 занят другим процессом. Освободите: ss -tlnp | grep 443"
  fi

  while true; do
    if [ -z "${DOMAIN:-}" ]; then
      prompt_line DOMAIN "Домен (A-запись → этот сервер)" ""
    fi
    [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
    DOMAIN="$(require_valid_domain_name "$DOMAIN")"
    export DOMAIN

    check_domain_dns "$DOMAIN"
    dns_rc=$?
    case "$dns_rc" in
      0) break ;;
      1)
        if is_auto_mode; then
          die "DNS: домен $DOMAIN не резолвится (нет A-записи)"
        fi
        if ! prompt_domain_dns_retry_or_exit; then
          die "Установка отменена"
        fi
        DOMAIN=""
        ;;
      2)
        if is_auto_mode; then
          die "DNS не указывает на этот сервер"
        fi
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
