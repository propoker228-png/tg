#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MENU_SH_VERSION="1.0"

pause_key_menu() {
  echo ""
  echo -n "Enter — назад в меню "
  read -r _ </dev/tty 2>/dev/null || read -r _
}

require_installed() {
  if [ ! -f /bin/telemt ]; then
    log_warn "Сначала выполните установку (пункт 1)"
    sleep 2
    return 1
  fi
  env_load_settings
  return 0
}

menu_install() {
  set +e
  handle_existing_env
  set -euo pipefail
  if [ "${SELECTED_ENV_ACTION:-}" = "keep" ]; then
    pause_key_menu
    return 0
  fi
  role_wizard_run
  pause_key_menu
}

menu_stats_snapshot() {
  require_installed || return 0
  show_stats_snapshot
  pause_key_menu
}

menu_services() {
  local c=""
  require_installed || return 0

  while true; do
    clear
    echo "=== Сервисы ==="
    echo "  telemt:      $(systemctl is-active telemt 2>/dev/null || echo inactive)"
    echo "  nginx:       $(systemctl is-active nginx 2>/dev/null || echo inactive)"
    echo "  mtpr-synfix: $(systemctl is-active mtpr-synfix 2>/dev/null || echo inactive)"
    echo ""
    echo "  1) Перезапустить telemt"
    echo "  2) Перезапустить nginx"
    echo "  3) Перезапустить mtpr-synfix"
    echo "  4) Лог telemt (20 строк)"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1)
        systemctl restart telemt
        wait_telemt_port_443 15 || log_warn "порт 443 ещё не слушается"
        log_ok "telemt перезапущен"
        ;;
      2)
        systemctl restart nginx
        log_ok "nginx перезапущен"
        ;;
      3)
        if systemctl list-unit-files mtpr-synfix.service &>/dev/null; then
          systemctl restart mtpr-synfix
          log_ok "mtpr-synfix перезапущен"
        else
          log_warn "mtpr-synfix не установлен"
        fi
        ;;
      4)
        journalctl -u telemt --no-pager -n 20
        pause_key_menu
        ;;
      0) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

menu_proxy_settings() {
  require_installed || return 0
  [ -n "${DOMAIN:-}" ] || { log_warn "Домен не задан"; pause_key_menu; return 0; }

  show_mtproxybot_handoff "$DOMAIN"
  prompt_ad_tag
  if [ -n "${AD_TAG:-}" ]; then
    export AD_TAG
    telemt_write_config
    systemctl restart telemt
    wait_telemt_port_443 30 || log_warn "ожидание порта 443"
    save_state
    log_ok "ad_tag применён"
  fi
  pause_key_menu
}

menu_ssl() {
  require_installed || return 0
  local cert="" days=0

  echo "=== SSL ==="
  if install_is_ip_only; then
    echo "  режим: только IP (без Let's Encrypt)"
    echo "  маскировка: ${TLS_DOMAIN:-н/д}"
    if [ -f /etc/telemt/selfsigned/fullchain.pem ]; then
      echo "  self-signed: есть (/etc/telemt/selfsigned/)"
      openssl x509 -in /etc/telemt/selfsigned/fullchain.pem -noout -dates 2>/dev/null || true
    else
      echo "  self-signed: отсутствует"
    fi
  elif [ -n "${DOMAIN:-}" ]; then
    cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    echo "  домен: ${DOMAIN}"
    if [ -f "$cert" ]; then
      echo "  сертификат: есть"
      openssl x509 -in "$cert" -noout -dates 2>/dev/null || true
      days=$(ssl_cert_days_left "$DOMAIN")
      [ "$days" -ge 0 ] && echo "  осталось дней: ${days}"
    else
      echo "  сертификат: отсутствует"
      if confirm_action "Выпустить сертификат через certbot?"; then
        ssl_obtain_cert "$DOMAIN"
      fi
    fi
    if ssl_renew_hook_installed; then
      echo "  автообновление: включено"
    else
      echo "  автообновление: не настроено"
    fi
    echo ""
    if confirm_action "Запустить certbot renew?"; then
      certbot renew --non-interactive || log_warn "certbot renew завершился с ошибкой"
    fi
  else
    log_warn "Домен не задан"
  fi
  pause_key_menu
}

menu_syn_fix() {
  local c=""
  require_installed || return 0
  env_load_settings 2>/dev/null || true
  SYN_FIX_MODE="${SYN_FIX_MODE:-meko}"

  while true; do
    clear
    echo "=== SYN-фикс / обход DPI ==="
    echo "  Режим: $(syn_fix_label)"
    echo ""
    case "${SYN_FIX_MODE:-meko}" in
      meko)
        meko_show_version_info
        echo ""
        echo "  1) Обновить MEKO SYN FIX"
        echo "  2) Переустановить правила (inline)"
        echo "  3) Диагностика hashlimit (benchmark)"
        ;;
      zapret2)
        echo "  Служба: $(zapret2_status_label)"
        echo "  NFQUEUE: ${ZAPRET2_QNUM:-?}  порт: ${PROXY_PORT:-443}"
        echo ""
        echo "  1) Перезапустить tg-zapret2"
        echo "  2) Переустановить Zapret2"
        ;;
      none)
        echo "  SYN-фикс не установлен."
        echo ""
        echo "  1) Установить SYN-фикс"
        ;;
    esac
    echo "  9) Сменить режим SYN-фикса"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1)
        case "${SYN_FIX_MODE:-meko}" in
          meko)
            if [ "$(meko_install_mode)" = "full" ]; then
              log_warn "Режим MEKO Launcher — inline-обновление недоступно"
              sleep 2
              continue
            fi
            if meko_update_available; then
              confirm_action "Обновить MEKO SYN FIX до v$(meko_bundled_version)?" \
                && meko_upgrade_inline
            else
              log_info "Установлена актуальная версия v$(meko_installed_version)"
              sleep 2
            fi
            ;;
          zapret2)
            confirm_action "Перезапустить tg-zapret2?" \
              && systemctl restart tg-zapret2.service \
              && log_ok "tg-zapret2 перезапущен"
            ;;
          none)
            pick_syn_fix_mode
            confirm_action "Установить $(syn_fix_label)?" && syn_fix_install && save_state
            ;;
        esac
        ;;
      2)
        case "${SYN_FIX_MODE:-meko}" in
          meko)
            if [ "$(meko_install_mode)" = "full" ]; then
              log_warn "Режим MEKO Launcher — используйте mekopr для переустановки"
              sleep 2
              continue
            fi
            confirm_action "Переустановить MEKO inline?" && meko_upgrade_inline
            ;;
          zapret2)
            confirm_action "Переустановить Zapret2?" && syn_fix_install && save_state
            ;;
        esac
        ;;
      3|benchmark|diag)
        syn_fix_is_meko || { log_warn "Доступно только для MEKO"; sleep 2; continue; }
        meko_diag_run_benchmark
        prompt_line c "Enter для продолжения" ""
        ;;
      9)
        pick_syn_fix_mode
        confirm_action "Применить $(syn_fix_label)? Текущий фикс будет заменён." \
          && syn_fix_install && save_state
        ;;
      0) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

menu_meko() {
  menu_syn_fix
}

menu_firewall() {
  require_installed || return 0

  echo "=== Firewall (UFW) ==="
  ufw status verbose 2>/dev/null || log_warn "ufw недоступен"
  echo ""
  if confirm_action "Применить firewall_setup (открыть 80/443)?"; then
    firewall_setup
  fi
  pause_key_menu
}

menu_verify() {
  local c=""
  require_installed || return 0
  [ -n "${DOMAIN:-}" ] || { log_warn "Домен не задан"; pause_key_menu; return 0; }

  while true; do
    clear
    echo "=== Проверки ==="
    echo "  1) Быстрая (verify)"
    echo "  2) Полная (doctor)"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1) run_doctor_quick "$DOMAIN"; pause_key_menu ;;
      2) run_doctor_full "$DOMAIN"; pause_key_menu ;;
      0) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
    [ "$c" = "1" ] || [ "$c" = "2" ] && break
  done
}

menu_upgrade_telemt() {
  local version cur=""
  require_installed || return 0

  [ -x /bin/telemt ] && cur=$(/bin/telemt --version 2>/dev/null | head -1 || true)
  echo "=== Обновление telemt ==="
  echo "  текущая: ${cur:-н/д}"
  TELEMT_VERSION=""
  prompt_line TELEMT_VERSION "Версия (пусто = latest)" ""
  export TELEMT_VERSION
  version=$(resolve_telemt_version)
  confirm_action "Установить telemt ${version}?" || return 0
  telemt_install_binary "$version"
  systemctl restart telemt
  wait_telemt_port_443 30 || log_warn "порт 443 ещё не слушается"
  log_ok "telemt обновлён до ${version}"
  pause_key_menu
}

menu_uninstall() {
  confirm_action "Удалить установленный стек telemt-deploy?" || return 0
  uninstall_all
  log_ok "Стек удалён"
  pause_key_menu
}

menu_shaping() {
  local c="" ip="" mbit="" iface=""
  require_installed || return 0
  shaping_ensure_config
  shaping_ensure_units

  while true; do
    clear
    shaping_load_config
    iface="$(monitor_default_iface)"
    echo "=== Шейпинг трафика (исходящий, Mbit/s) ==="
    echo "  Интерфейс: ${iface:-н/д}"
    if [ "${SHAPING_ENABLED:-0}" -eq 1 ] && awk -v g="${SHAPING_GLOBAL_MBIT:-0}" 'BEGIN { exit !(g > 0) }'; then
      echo "  Глобальный лимит: ${SHAPING_GLOBAL_MBIT} Mbit/s"
      echo "  Статус: включён"
    elif [ "${SHAPING_ENABLED:-0}" -eq 1 ]; then
      echo "  Глобальный лимит: выкл (только индивидуальные override)"
      echo "  Статус: включён"
    else
      echo "  Глобальный лимит: выкл"
      echo "  Статус: выключен"
    fi
    echo ""
    echo "  Активные IP:"
    local count=0
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      echo "    ${ip}   $(shaping_format_ip_limit "$ip")"
      count=$((count + 1))
    done < <(shaping_collect_active_ips | sort -u)
    [ "$count" -eq 0 ] && echo "    (нет)"
    echo ""
    echo "  1) Задать глобальный лимит (Mbit/s, 0 = выкл)"
    echo "  2) Задать лимит для IP"
    echo "  3) Снять лимит с IP (без лимита)"
    echo "  4) Убрать индивидуальный override"
    echo "  5) Применить правила сейчас"
    echo "  6) Выключить шейпинг полностью"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1)
        prompt_line mbit "Глобальный лимит Mbit/s (0 = выкл)" "${SHAPING_GLOBAL_MBIT:-0}"
        if shaping_set_global_limit "$mbit"; then
          shaping_apply && log_ok "Глобальный лимит применён" || log_warn "Конфиг сохранён, tc apply не удался"
        else
          log_warn "Некорректное значение Mbit/s"
        fi
        sleep 1
        ;;
      2)
        ip="$(shaping_pick_ip)" || { sleep 1; continue; }
        prompt_line mbit "Лимит Mbit/s для ${ip}" ""
        if shaping_validate_mbit "$mbit" && awk -v v="$mbit" 'BEGIN { exit !(v > 0) }'; then
          shaping_load_config
          shaping_save_config 1 "${SHAPING_GLOBAL_MBIT:-0}" "$SHAPING_OVERRIDES_JSON"
          shaping_override_set_mbit "$ip" "$mbit"
          shaping_apply && log_ok "Лимит ${mbit} Mbit/s для ${ip}" || log_warn "Конфиг сохранён, tc apply не удался"
        else
          log_warn "Введите положительное число Mbit/s"
        fi
        sleep 1
        ;;
      3)
        ip="$(shaping_pick_ip)" || { sleep 1; continue; }
        shaping_load_config
        shaping_save_config 1 "${SHAPING_GLOBAL_MBIT:-0}" "$SHAPING_OVERRIDES_JSON"
        shaping_override_set_unlimited "$ip"
        shaping_apply && log_ok "IP ${ip} без лимита" || log_warn "Конфиг сохранён, tc apply не удался"
        sleep 1
        ;;
      4)
        ip="$(shaping_pick_ip)" || { sleep 1; continue; }
        if shaping_has_override "$ip"; then
          shaping_override_remove "$ip"
          shaping_apply && log_ok "Override для ${ip} удалён" || log_warn "Конфиг сохранён, tc apply не удался"
        else
          log_warn "Для ${ip} нет индивидуального override"
          sleep 1
        fi
        ;;
      5)
        if shaping_apply; then
          log_ok "Правила tc применены"
        else
          log_warn "Не удалось применить правила tc"
        fi
        sleep 1
        ;;
      6)
        shaping_disable_all
        shaping_apply && log_ok "Шейпинг выключен" || log_warn "Конфиг обновлён, tc apply не удался"
        sleep 1
        ;;
      0) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}

main_menu() {
  local choice=""

  while true; do
    clear
    render_menu_header "${INSTALLER_VERSION:-2.4}"
    echo ""
    echo "  1)  Установка / переустановка"
    echo "  2)  Статистика (разово)"
    echo "  3)  Мониторинг (live)"
    echo "  4)  Сервисы"
    echo "  5)  Настройки прокси"
    echo "  6)  SSL"
    echo "  7)  SYN-фикс / обход DPI"
    echo "  8)  Firewall"
    echo "  9)  Проверки"
    echo "  10) Обновить telemt"
    echo "  11) Удалить стек"
    echo "  12) Кластер / мульти-прокси"
    echo "  13) Шейпинг трафика"
    echo "  0)  Выход"
    echo ""
    prompt_line choice "Выбор" ""
    case "$choice" in
      1) menu_install ;;
      2) menu_stats_snapshot ;;
      3)
        require_installed || continue
        run_live_monitor
        ;;
      4) menu_services ;;
      5) menu_proxy_settings ;;
      6) menu_ssl ;;
      7) menu_syn_fix ;;
      8) menu_firewall ;;
      9) menu_verify ;;
      10) menu_upgrade_telemt ;;
      11) menu_uninstall ;;
      12) menu_cluster ;;
      13) menu_shaping ;;
      0|q|Q) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
  clear
}
