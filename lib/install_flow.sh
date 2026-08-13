#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=install_step.sh
source "$(dirname "${BASH_SOURCE[0]}")/install_step.sh"

INSTALL_FLOW_SH_VERSION="1.3"

_install_step_ssl_obtain_cert() {
  ssl_obtain_cert "$DOMAIN"
}

_install_step_ssl_self_signed() {
  ssl_install_self_signed "$TLS_DOMAIN"
}

_install_step_ssl_renew_hook() {
  ssl_install_renew_hook
}

_install_step_verify() {
  verify_install "$DOMAIN"
}

_install_step_handoff() {
  show_mtproxybot_handoff "$DOMAIN"
}

_install_step_ad_tag_restart() {
  [ -n "${AD_TAG:-}" ] || return 0
  systemctl restart telemt
  wait_telemt_port_443 30 || log_warn "telemt перезапущен, ожидание порта 443 продолжается"
  verify_install "$DOMAIN" || log_warn "Проверка после применения ad_tag выявила проблемы"
}

_install_step_save_state() {
  save_state
}

_install_step_tg_command() {
  install_tg_command
}

_install_step_syn_fix_upgrade() {
  syn_fix_upgrade_if_needed
}

_install_step_online_stats() {
  show_proxy_online_stats
}

_install_flow_build_steps() {
  INSTALL_FLOW_STEPS=()
  INSTALL_FLOW_STEPS+=("prereq|Пакеты и sysctl|0|prereq_install")

  if install_is_ip_only; then
    INSTALL_FLOW_STEPS+=("ssl_self|Self-signed SSL|1|_install_step_ssl_self_signed")
    INSTALL_FLOW_STEPS+=("nginx|nginx (production)|1|nginx_install_production")
  else
    INSTALL_FLOW_STEPS+=("nginx_temp|nginx (ACME)|1|nginx_install_temp")
    INSTALL_FLOW_STEPS+=("ssl|Let's Encrypt|1|_install_step_ssl_obtain_cert")
    INSTALL_FLOW_STEPS+=("ssl_renew|Автообновление SSL|1|_install_step_ssl_renew_hook")
    INSTALL_FLOW_STEPS+=("nginx|nginx (production)|1|nginx_install_production")
  fi

  INSTALL_FLOW_STEPS+=("telemt|telemt|0|telemt_install")
  INSTALL_FLOW_STEPS+=("syn_fix|SYN-фикс|1|syn_fix_install")
  INSTALL_FLOW_STEPS+=("firewall|UFW|1|firewall_setup")
  INSTALL_FLOW_STEPS+=("verify|Проверка установки|1|_install_step_verify")
  INSTALL_FLOW_STEPS+=("handoff|Данные для @MTProxybot|1|_install_step_handoff")
  INSTALL_FLOW_STEPS+=("ad_tag|Применение ad_tag|1|_install_step_ad_tag_restart")
  INSTALL_FLOW_STEPS+=("state|Сохранение состояния|0|_install_step_save_state")
  INSTALL_FLOW_STEPS+=("tg_cmd|Команда tg|1|_install_step_tg_command")
  INSTALL_FLOW_STEPS+=("syn_upgrade|Обновление SYN-фикса|1|_install_step_syn_fix_upgrade")
  INSTALL_FLOW_STEPS+=("stats|Статистика прокси|1|_install_step_online_stats")
}

run_install_flow() {
  local i=0 total=0 step_id="" step_label="" skippable="" step_func="" rc=0

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

  install_step_reset
  _install_flow_build_steps
  total="${#INSTALL_FLOW_STEPS[@]}"

  i=0
  while [ "$i" -lt "$total" ]; do
    IFS='|' read -r step_id step_label skippable step_func <<< "${INSTALL_FLOW_STEPS[$i]}"
    log_info "── Этап $((i + 1))/${total}: ${step_label} ──"

    install_step_run "$step_id" "$step_label" "$skippable" "$step_func" || {
      rc=$?
      case "$rc" in
        2)
          if [ "$i" -gt 0 ]; then
            i=$((i - 1))
            log_info "Возврат к предыдущему этапу"
          else
            log_warn "Это первый этап — выберите повтор или прервите установку"
          fi
          continue
          ;;
        *)
          log_err "Установка прервана на этапе: ${step_label}"
          return 1
          ;;
      esac
    }
    i=$((i + 1))
  done

  install_step_show_skipped_summary
  log_ok "Установка завершена"
  log_info "Меню управления: tg"
  return 0
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
    DOMAIN="$(trim_whitespace "$DOMAIN")"
    if is_valid_ipv4 "$DOMAIN"; then
      INSTALL_IP_ONLY=1
      export DOMAIN INSTALL_IP_ONLY
      log_ok "Обнаружен IP-адрес — режим без Let's Encrypt (self-signed SSL)"
      return 0
    fi
    DOMAIN="$(require_valid_domain_name "$DOMAIN")"
    export DOMAIN
    while true; do
      dns_rc=0
      check_domain_dns "$DOMAIN" || dns_rc=$?
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
    DOMAIN="$(trim_whitespace "$DOMAIN")"
    if is_valid_ipv4 "$DOMAIN"; then
      INSTALL_IP_ONLY=1
      export DOMAIN INSTALL_IP_ONLY
      log_ok "Обнаружен IP-адрес — режим без Let's Encrypt (self-signed SSL)"
      return 0
    fi
    DOMAIN="$(require_valid_domain_name "$DOMAIN")"
    export DOMAIN

    dns_rc=0
    check_domain_dns "$DOMAIN" || dns_rc=$?
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
