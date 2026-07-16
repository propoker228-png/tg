#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_FLOW_SH_VERSION="1.0"

run_install_flow() {
  [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
  export DOMAIN

  log_info "Старт установки для ${DOMAIN}"

  prereq_install
  nginx_install_temp
  ssl_obtain_cert "$DOMAIN"
  nginx_install_production
  telemt_install
  meko_install
  firewall_setup
  verify_install "$DOMAIN" || log_warn "Проверка выявила проблемы, продолжаем handoff"

  show_mtproxybot_handoff "$DOMAIN"
  prompt_ad_tag

  if [ -n "${AD_TAG:-}" ]; then
    export AD_TAG
    telemt_write_config
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
  if port_in_use 443 && ! telemt_listens_443; then
    die "Порт 443 занят другим процессом. Освободите: ss -tlnp | grep 443"
  fi

  if [ -z "${DOMAIN:-}" ]; then
    prompt_line DOMAIN "Домен (A-запись → этот сервер)" ""
  fi
  [ -n "${DOMAIN:-}" ] || die "Домен обязателен"
  DOMAIN="$(require_valid_domain_name "$DOMAIN")"
  export DOMAIN

  validate_domain_dns "$DOMAIN"

  if ! is_auto_mode; then
    confirm_action "Начать установку для домена ${DOMAIN}?" || die "Установка отменена"
  fi
}
