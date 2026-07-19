#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENV_SH_VERSION="2.2"
SELECTED_ENV_ACTION=""

env_telemt_active() {
  systemctl is-active --quiet telemt 2>/dev/null
}

env_nginx_telemt_configured() {
  [ -f /etc/nginx/sites-enabled/telemt-site ] \
    || [ -f /etc/nginx/sites-available/telemt-site ]
}

env_meko_configured() {
  [ -f /etc/systemd/system/mtpr-synfix.service ] \
    || [ -d /opt/mtpr-simple ]
}

env_collect_components() {
  ENV_COMPONENTS=()

  [ -f "$STATE_FILE" ] && ENV_COMPONENTS+=("state: $STATE_FILE")
  [ -f "$SECRET_FILE" ] && ENV_COMPONENTS+=("secret: $SECRET_FILE")
  [ -f /bin/telemt ] && ENV_COMPONENTS+=("binary: /bin/telemt")
  [ -f /etc/telemt/telemt.toml ] && ENV_COMPONENTS+=("config: /etc/telemt/telemt.toml")
  [ -f /etc/systemd/system/telemt.service ] && ENV_COMPONENTS+=("unit: telemt.service")
  env_telemt_active && ENV_COMPONENTS+=("service: telemt (active)")
  env_nginx_telemt_configured && ENV_COMPONENTS+=("nginx: telemt-site")
  env_meko_configured && ENV_COMPONENTS+=("meko: mtpr-synfix")
  if telemt_listens_443; then
    ENV_COMPONENTS+=("listen: tcp/443 (telemt)")
  fi
}

existing_env_detected() {
  env_collect_components
  [ "${#ENV_COMPONENTS[@]}" -gt 0 ]
}

env_load_settings() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    export DOMAIN SECRET AD_TAG TLS_DOMAIN INSTALL_IP_ONLY
  fi

  if [ -z "${SECRET:-}" ] && [ -f "$SECRET_FILE" ]; then
    SECRET=$(cat "$SECRET_FILE")
    export SECRET
  fi

  if [ -z "${SECRET:-}" ] && [ -f /etc/telemt/telemt.toml ]; then
    SECRET=$(awk -F'"' '/^default = / { print $2; exit }' /etc/telemt/telemt.toml)
    export SECRET
  fi

  if [ -z "${DOMAIN:-}" ] && [ -f /etc/telemt/telemt.toml ]; then
    DOMAIN=$(
      awk -F'"' '/^public_host = / { print $2; exit }' /etc/telemt/telemt.toml
    )
    export DOMAIN
  fi

  if [ -z "${TLS_DOMAIN:-}" ] && [ -f /etc/telemt/telemt.toml ]; then
    TLS_DOMAIN=$(
      awk -F'"' '/^tls_domain = / { print $2; exit }' /etc/telemt/telemt.toml
    )
    export TLS_DOMAIN
  fi
  TLS_DOMAIN="${TLS_DOMAIN:-$DOMAIN}"
  if [ -z "${INSTALL_IP_ONLY:-}" ] && is_valid_ipv4 "${DOMAIN:-}"; then
    INSTALL_IP_ONLY=1
  fi
  export INSTALL_IP_ONLY

  [ -n "${AD_TAG:-}" ] && export AD_TAG
}

env_show_summary() {
  local item domain="${DOMAIN:-}" telemt_ver="н/д"

  env_load_settings
  [ -x /bin/telemt ] && telemt_ver=$(/bin/telemt --version 2>/dev/null | head -1 || echo "н/д")

  echo ""
  echo "=============================================="
  echo "  Найдена установка telemt-deploy"
  echo "=============================================="
  for item in "${ENV_COMPONENTS[@]}"; do
    echo "  * $item"
  done
  [ -n "$domain" ] && echo "  * домен: ${domain}"
  echo "  * telemt: ${telemt_ver}"
  echo "=============================================="
  echo ""
}

env_prompt_action() {
  SELECTED_ENV_ACTION=""

  if [ "${FRESH:-0}" -eq 1 ]; then
    SELECTED_ENV_ACTION="reinstall"
    return 0
  fi
  if [ "${KEEP_EXISTING:-0}" -eq 1 ]; then
    SELECTED_ENV_ACTION="keep"
    return 0
  fi

  prompt_choice_12 SELECTED_ENV_ACTION "Выберите действие для существующей установки"
}

keep_existing_env() {
  env_load_settings

  if [ -z "${DOMAIN:-}" ]; then
    log_warn "Домен не найден — пропускаем проверки"
    return 0
  fi

  export DOMAIN
  log_info "Оставляем текущую установку для ${DOMAIN}"

  if env_telemt_active; then
    verify_install "$DOMAIN" || log_warn "Текущая установка требует внимания"
  else
    log_warn "telemt не запущен — запустите: systemctl start telemt"
  fi

  if [ -z "${AD_TAG:-}" ]; then
    show_mtproxybot_handoff "$DOMAIN"
    prompt_ad_tag
    if [ -n "${AD_TAG:-}" ]; then
      telemt_write_config
      systemctl restart telemt
      wait_telemt_port_443 30 || log_warn "telemt перезапущен, ожидание порта 443 продолжается"
      verify_install "$DOMAIN" || log_warn "Проверка после применения ad_tag выявила проблемы"
    fi
  elif [ -n "${PROXY_LINK:-}" ]; then
    echo ""
    echo -e "${BOLD}Ссылка:${NC} $PROXY_LINK"
  fi

  save_state
  if [ ! -x /usr/local/bin/tg ]; then
    install_tg_command
  fi
  meko_upgrade_if_needed
  log_ok "Окружение оставлено без изменений"
}

handle_existing_env() {
  echo "[i] Проверка существующей установки..."

  if ! existing_env_detected; then
    echo "[i] Существующая установка не обнаружена"
    return 0
  fi

  env_show_summary
  env_prompt_action

  case "$SELECTED_ENV_ACTION" in
    reinstall)
      if ! is_auto_mode; then
        confirm_action "Удалить текущую установку и продолжить с чистого листа?" \
          || die "Установка отменена пользователем"
      fi
      log_warn "Удаление текущей установки перед чистой установкой..."
      uninstall_all
      log_ok "Среда очищена, продолжаем установку"
      ;;
    keep)
      keep_existing_env
      if [ "${MENU_MODE:-0}" -eq 1 ]; then
        return 0
      fi
      exit 0
      ;;
    *)
      die "Неизвестное действие: $SELECTED_ENV_ACTION"
      ;;
  esac
}
