#!/bin/bash
# telemt-deploy — установка telemt + nginx self-mask + MEKO SYN FIX
#
# Использование: sudo bash install.sh [флаги]
#
# Без флагов — интерактивное меню управления (п. 1–15).
#
#   --domain DOMAIN         Домен (A-запись → этот сервер)
#   --tls-domain DOMAIN     Домен маскировки TLS/SNI (обязателен с --ip-only)
#   --ip-only               Установка без своего домена (подключение по IP сервера)
#   --ad-tag HEX32          ad_tag из @MTProxybot (32 hex)
#   --telemt-version VER    Версия telemt (предвыбор в меню версий)
#   --meko-version VER      Версия MEKO (предвыбор в меню версий)
#   --meko-full             Полный MEKO Launcher вместо inline SYN fix
#   --yes                   Авто-подтверждение (без лишних y/N; выбор версий остаётся)
#   --fresh                 Удалить найденную установку и поставить с нуля (без вопросов)
#   --keep                  Оставить найденную установку как есть (без вопросов)
#   --status                Показать статус и число подключённых (как в MEKO)
#   --meko-upgrade          Обновить MEKO SYN FIX до версии из комплекта
#   --meko-benchmark        Диагностика MEKO hashlimit (ACCEPT/REJECT, burst)
#   --doctor                Полная диагностика (tg doctor)
#   --speedtest             Тест скорости интернета на сервере
#   --uninstall             Удалить установленный стек (секрет и SSL сохраняются)
#   --purge                 С --uninstall: полное удаление (секрет, certbot, /opt/telemt*)
#   --role ROLE             standalone | node | lb | master | master_lb (кластер)
#   --proxy-mode MODE       tls (Fake TLS, default) | secure (Obfuscated2/dd); только standalone
#   --syn-fix MODE          meko (default) | zapret2 | none — SYN-фикс / обход DPI
#   --stub-site THEME       Сайт-заглушка: it-services, managed-ftp, global-cdn, marketplace, ...
#   --cluster-domain DOMAIN Публичный домен ссылки (для кластера)
#   --cluster-secret HEX    Секрет кластера (для node)
#   --node SPEC             Backend для LB: name:ip:port (можно несколько раз)
#
# Подкоманды (через tg или install.sh):
#   doctor [--quick]        Диагностика (полная или быстрая)
#   link [--qr]             Ссылка прокси (+ QR)
#   backup                  Создать бэкап
#   restore FILE [--force]  Восстановить бэкап
#   -h, --help              Показать справку
#
set -euo pipefail

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  DEPLOY_ROOT="/root/telemt-deploy"
fi
export DEPLOY_ROOT

remote_bootstrap() {
  if [ ! -f "$DEPLOY_ROOT/lib/common.sh" ]; then
    echo "Локальные lib/ не найдены. Запустите из клонированного репозитория telemt-deploy/" >&2
    exit 1
  fi
}

DOMAIN=""; TLS_DOMAIN=""; INSTALL_IP_ONLY=0; AD_TAG=""; TELEMT_VERSION=""; MEKO_VERSION=""; YES=0; MEKO_FULL=0; UNINSTALL=0; PURGE=0
FRESH=0; KEEP_EXISTING=0; STATUS=0; MEKO_UPGRADE=0; MEKO_BENCHMARK=0; DOCTOR=0; SPEEDTEST=0; STUB_SITE=""; SYN_FIX_MODE=""
SYN_FIX_CLI_SET=0
PROXY_MODE="tls"; PROXY_MODE_CLI=""
CLUSTER_ROLE="standalone"; CLUSTER_DOMAIN=""; CLUSTER_SECRET=""
CLUSTER_NODES=""
MASTER_PANEL_URL=""; NODE_NAME=""; CLUSTER_AGENT_TOKEN=""
SUBCOMMAND=""

if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
  SUBCOMMAND="$1"
  shift
fi

require_arg_value() {
  local flag="$1" value="${2:-}"
  if [ -z "$value" ] || [[ "$value" == --* ]]; then
    echo "Флаг $flag требует значение" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --tls-domain) TLS_DOMAIN=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --ip-only) INSTALL_IP_ONLY=1; shift ;;
    --ad-tag) AD_TAG=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --telemt-version) TELEMT_VERSION=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --meko-version) MEKO_VERSION=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --meko-full) MEKO_FULL=1; shift ;;
    --yes) YES=1; shift ;;
    --fresh|--reinstall) FRESH=1; shift ;;
    --keep|--keep-existing) KEEP_EXISTING=1; shift ;;
    --status) STATUS=1; shift ;;
    --meko-upgrade) MEKO_UPGRADE=1; shift ;;
    --meko-benchmark) MEKO_BENCHMARK=1; shift ;;
    --doctor) DOCTOR=1; shift ;;
    --speedtest) SPEEDTEST=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    --role) CLUSTER_ROLE=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --proxy-mode) PROXY_MODE_CLI=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --syn-fix) SYN_FIX_MODE=$(require_arg_value "$1" "${2:-}"); SYN_FIX_CLI_SET=1; shift 2 ;;
    --stub-site) STUB_SITE=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --cluster-domain) CLUSTER_DOMAIN=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --cluster-secret) CLUSTER_SECRET=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --node) CLUSTER_NODES="$CLUSTER_NODES $(require_arg_value "$1" "${2:-}")"; shift 2 ;;
    --master-panel-url) MASTER_PANEL_URL=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --node-name) NODE_NAME=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --cluster-agent-token) CLUSTER_AGENT_TOKEN=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    -h|--help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $1" >&2
      exit 1
      ;;
  esac
done

export TELEMT_VERSION MEKO_VERSION MEKO_FULL YES FRESH KEEP_EXISTING MEKO_UPGRADE MEKO_BENCHMARK DOCTOR SPEEDTEST INSTALL_IP_ONLY STUB_SITE SYN_FIX_MODE SYN_FIX_CLI_SET
[ "$CLUSTER_ROLE" = "master-lb" ] && CLUSTER_ROLE=master_lb
export CLUSTER_ROLE CLUSTER_DOMAIN CLUSTER_SECRET CLUSTER_NODES MASTER_PANEL_URL NODE_NAME CLUSTER_AGENT_TOKEN
[ -n "$TLS_DOMAIN" ] && export TLS_DOMAIN
[ -n "$AD_TAG" ] && export AD_TAG

case "$CLUSTER_ROLE" in
  standalone|node|lb|master|master_lb|master-lb) ;;
  *) echo "Неизвестная роль --role: $CLUSTER_ROLE (допустимо: standalone, node, lb, master, master_lb)" >&2; exit 1 ;;
esac
export CLUSTER_ROLE

remote_bootstrap

# shellcheck source=lib/common.sh
source "$DEPLOY_ROOT/lib/common.sh"
for mod in proxy_mode prereq stub_site syn_fix zapret2 dns nginx ssl ssl_renew telemt meko meko_stats meko_diag firewall dialog ui_highlight mask_picker version_picker sni_check haproxy cluster panel cluster_agent cluster_migrate cluster_panel role_wizard link backup doctor verify handoff uninstall env stats monitor shaping access_limits speedtest install_step install_flow cli_tools menu; do
  # shellcheck source=/dev/null
  source "$DEPLOY_ROOT/lib/${mod}.sh"
done

[ -n "$PROXY_MODE_CLI" ] && normalize_proxy_mode "$PROXY_MODE_CLI"
proxy_mode_force_tls_for_cluster
export PROXY_MODE
proxy_mode_warn_ip_only_secure

if [ "$FRESH" -eq 1 ] && [ "$KEEP_EXISTING" -eq 1 ]; then
  die "Нельзя одновременно использовать --fresh и --keep"
fi

if [ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -ne 1 ]; then
  die "Флаг --purge можно использовать только вместе с --uninstall"
fi
export PURGE

validate_cli_inputs() {
  if [ "${INSTALL_IP_ONLY:-0}" -eq 1 ]; then
    [ -n "${TLS_DOMAIN:-}" ] || die "Флаг --ip-only требует --tls-domain"
    DOMAIN="$(get_public_ip)"
    TLS_DOMAIN="$(require_valid_domain_name "$TLS_DOMAIN")"
    export DOMAIN TLS_DOMAIN INSTALL_IP_ONLY
  else
    if [ -n "$DOMAIN" ]; then
      if is_valid_ipv4 "$DOMAIN"; then
        INSTALL_IP_ONLY=1
        export DOMAIN INSTALL_IP_ONLY
      else
        DOMAIN="$(require_valid_domain_name "$DOMAIN")"
        export DOMAIN
      fi
    fi
    if [ -n "$TLS_DOMAIN" ]; then
      TLS_DOMAIN="$(require_valid_domain_name "$TLS_DOMAIN")"
      export TLS_DOMAIN
    fi
  fi
  [ -z "$AD_TAG" ] || require_valid_ad_tag "$AD_TAG"
  [ -z "$TELEMT_VERSION" ] || require_valid_telemt_version "$TELEMT_VERSION"
  [ -z "$MEKO_VERSION" ] || require_valid_meko_version "$MEKO_VERSION"
  if [ -n "$STUB_SITE" ]; then
    STUB_SITE=$(stub_site_resolve "$STUB_SITE") || die "Неизвестный --stub-site: $STUB_SITE"
    export STUB_SITE
  fi
  if [ -n "$SYN_FIX_MODE" ]; then
    SYN_FIX_MODE=$(syn_fix_resolve "$SYN_FIX_MODE") || die "Неизвестный --syn-fix: $SYN_FIX_MODE (meko|zapret2|none)"
    export SYN_FIX_MODE
  fi
  if [ -n "$CLUSTER_DOMAIN" ]; then
    CLUSTER_DOMAIN="$(require_valid_domain_name "$CLUSTER_DOMAIN")"
    export CLUSTER_DOMAIN
  fi
}

validate_cli_inputs

INSTALLER_VERSION="3.0"

on_err() {
  echo "[X] Сбой установки (строка ${1:-?} в ${2:-install.sh})" >&2
  exit 1
}

trap 'on_err $LINENO ${BASH_SOURCE[0]##*/}' ERR

has_action_flags() {
  [ "$UNINSTALL" -eq 1 ] || [ "$STATUS" -eq 1 ] || [ "$FRESH" -eq 1 ] || \
    [ "$KEEP_EXISTING" -eq 1 ] || [ "$MEKO_UPGRADE" -eq 1 ] || [ -n "$DOMAIN" ] || [ -n "$TLS_DOMAIN" ] || \
    [ "${INSTALL_IP_ONLY:-0}" -eq 1 ] || \
    [ -n "$AD_TAG" ] || [ -n "$TELEMT_VERSION" ] || [ -n "$MEKO_VERSION" ] || [ "$MEKO_FULL" -eq 1 ] || \
    [ "$CLUSTER_ROLE" != "standalone" ] || [ -n "$CLUSTER_DOMAIN" ] || [ -n "${CLUSTER_NODES# }" ]
}

prepare_cluster_domain() {
  if [ -z "${CLUSTER_DOMAIN:-}" ]; then
    prompt_line CLUSTER_DOMAIN "Кластерный домен (для единой ссылки)" ""
  fi
  [ -n "${CLUSTER_DOMAIN:-}" ] || die "Кластерный домен обязателен"
  CLUSTER_DOMAIN="$(require_valid_domain_name "$CLUSTER_DOMAIN")"
  export CLUSTER_DOMAIN
}

require_lib_bundle() {
  local missing=0
  if [ "${COMMON_SH_VERSION:-}" != "2.2" ] && [ "${COMMON_SH_VERSION:-}" != "2.3" ]; then
    echo "[X] Устаревший lib/common.sh (нужен v2.2+) — скопируйте lib/common.sh на сервер" >&2
    missing=1
  fi
  if [ "${ENV_SH_VERSION:-}" != "2.2" ] && [ "${ENV_SH_VERSION:-}" != "2.3" ]; then
    echo "[X] Устаревший lib/env.sh (нужен v2.2+) — скопируйте lib/env.sh на сервер" >&2
    missing=1
  fi
  if [ "${STATS_SH_VERSION:-}" != "2.4.0" ]; then
    echo "[X] Отсутствует lib/stats.sh (v2.4.0) — скопируйте lib/stats.sh на сервер" >&2
    missing=1
  fi
  if [ "${MENU_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/menu.sh (v1.0) — скопируйте lib/menu.sh на сервер" >&2
    missing=1
  fi
  if [ "${MONITOR_SH_VERSION:-}" != "1.0" ] && [ "${MONITOR_SH_VERSION:-}" != "1.1" ] && [ "${MONITOR_SH_VERSION:-}" != "1.2" ]; then
    echo "[X] Устаревший lib/monitor.sh (нужен v1.0+) — скопируйте lib/monitor.sh на сервер" >&2
    missing=1
  fi
  if [ "${SHAPING_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/shaping.sh (v1.0) — скопируйте lib/shaping.sh на сервер" >&2
    missing=1
  fi
  if [ "${ACCESS_LIMITS_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/access_limits.sh (v1.0)" >&2
    missing=1
  fi
  case "${SPEEDTEST_SH_VERSION:-}" in
    1.0|1.1|1.2|1.3|1.4|1.5|1.6|1.7|1.8|1.9|1.10|1.11|1.12|1.13|1.14|1.15|1.16|1.17|1.18) ;;
    *)
      echo "[X] Устаревший lib/speedtest.sh (найден v${SPEEDTEST_SH_VERSION:-?}, нужен v1.0–1.18) — git pull в каталоге репозитория" >&2
      missing=1
      ;;
  esac
  if [ "${DIALOG_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/dialog.sh (v1.0) — скопируйте lib/dialog.sh на сервер" >&2
    missing=1
  fi
  if [ "${INSTALL_FLOW_SH_VERSION:-}" != "1.1" ] && [ "${INSTALL_FLOW_SH_VERSION:-}" != "1.2" ] && [ "${INSTALL_FLOW_SH_VERSION:-}" != "1.3" ]; then
    echo "[X] Устаревший lib/install_flow.sh (нужен v1.1+) — скопируйте lib/install_flow.sh на сервер" >&2
    missing=1
  fi
  if [ "${INSTALL_STEP_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/install_step.sh (v1.0) — скопируйте lib/install_step.sh на сервер" >&2
    missing=1
  fi
  if [ "${MEKO_SH_VERSION:-}" != "1.2" ] && [ "${MEKO_SH_VERSION:-}" != "1.3" ] && [ "${MEKO_SH_VERSION:-}" != "1.4" ]; then
    echo "[X] Устаревший lib/meko.sh (нужен v1.2+) — скопируйте lib/meko.sh на сервер" >&2
    missing=1
  fi
  if [ "${MEKO_STATS_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/meko_stats.sh (v1.0) — скопируйте lib/meko_stats.sh на сервер" >&2
    missing=1
  fi
  if [ "${MEKO_DIAG_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/meko_diag.sh (v1.0) — скопируйте lib/meko_diag.sh на сервер" >&2
    missing=1
  fi
  if [ "${UI_HIGHLIGHT_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/ui_highlight.sh (v1.0) — скопируйте lib/ui_highlight.sh на сервер" >&2
    missing=1
  fi
  if [ "${VERSION_PICKER_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/version_picker.sh (v1.0) — скопируйте lib/version_picker.sh на сервер" >&2
    missing=1
  fi
  if [ "${MASK_PICKER_SH_VERSION:-}" != "1.0" ] && [ "${MASK_PICKER_SH_VERSION:-}" != "1.1" ] && [ "${MASK_PICKER_SH_VERSION:-}" != "1.2" ]; then
    echo "[X] Устаревший lib/mask_picker.sh (нужен v1.0+) — скопируйте lib/mask_picker.sh на сервер" >&2
    missing=1
  fi
  if [ "${PROXY_MODE_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/proxy_mode.sh (v1.0) — скопируйте lib/proxy_mode.sh на сервер" >&2
    missing=1
  fi
  if [ "${STUB_SITE_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/stub_site.sh (v1.0) — скопируйте lib/stub_site.sh на сервер" >&2
    missing=1
  fi
  if [ "${SYN_FIX_SH_VERSION:-}" != "1.0" ] && [ "${SYN_FIX_SH_VERSION:-}" != "1.1" ]; then
    echo "[X] Устаревший lib/syn_fix.sh (нужен v1.0+) — скопируйте lib/syn_fix.sh на сервер" >&2
    missing=1
  fi
  if [ "${ZAPRET2_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/zapret2.sh (v1.0) — скопируйте lib/zapret2.sh на сервер" >&2
    missing=1
  fi
  if [ "${LINK_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/link.sh (v1.0) — скопируйте lib/link.sh на сервер" >&2
    missing=1
  fi
  if [ "${BACKUP_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/backup.sh (v1.0) — скопируйте lib/backup.sh на сервер" >&2
    missing=1
  fi
  if [ "${SSL_RENEW_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/ssl_renew.sh (v1.0) — скопируйте lib/ssl_renew.sh на сервер" >&2
    missing=1
  fi
  if [ "${SNI_CHECK_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/sni_check.sh (v1.0) — скопируйте lib/sni_check.sh на сервер" >&2
    missing=1
  fi
  if [ "${VERIFY_SH_VERSION:-}" != "1.1" ]; then
    echo "[X] Устаревший lib/verify.sh (нужен v1.1) — скопируйте lib/verify.sh на сервер" >&2
    missing=1
  fi
  if [ "${DOCTOR_SH_VERSION:-}" != "1.0" ] && [ "${DOCTOR_SH_VERSION:-}" != "1.1" ]; then
    echo "[X] Устаревший lib/doctor.sh (нужен v1.0+) — скопируйте lib/doctor.sh на сервер" >&2
    missing=1
  fi
  if [ "${CLI_TOOLS_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/cli_tools.sh (v1.0) — скопируйте lib/cli_tools.sh на сервер" >&2
    missing=1
  fi
  if [ "${CLUSTER_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/cluster.sh (v1.0) — скопируйте lib/cluster.sh на сервер" >&2
    missing=1
  fi
  if [ "${HAPROXY_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/haproxy.sh (v1.0) — скопируйте lib/haproxy.sh на сервер" >&2
    missing=1
  fi
  if [ "${ROLE_WIZARD_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/role_wizard.sh (v1.0)" >&2
    missing=1
  fi
  if [ "${PANEL_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/panel.sh (v1.0)" >&2
    missing=1
  fi
  if [ "${CLUSTER_AGENT_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/cluster_agent.sh (v1.0)" >&2
    missing=1
  fi
  if [ "${CLUSTER_MIGRATE_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/cluster_migrate.sh (v1.0)" >&2
    missing=1
  fi
  if [ "${CLUSTER_PANEL_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/cluster_panel.sh (v1.0)" >&2
    missing=1
  fi
  if [ "$missing" -eq 1 ]; then
    echo "    PowerShell: scp ...\\lib\\*.sh root@SERVER:~/telemt-deploy/lib/" >&2
    exit 1
  fi
}

require_lib_bundle
require_root
require_ubuntu
ensure_base_packages

dispatch_subcommand() {
  env_load_settings 2>/dev/null || true
  case "$SUBCOMMAND" in
    doctor)
      if [ "${1:-}" = "--quick" ]; then
        [ -n "${DOMAIN:-}" ] || die "Домен не задан"
        run_doctor_quick "$DOMAIN"
      else
        run_doctor_full "${DOMAIN:-}"
      fi
      exit $?
      ;;
    link)
      show_proxy_link "${1:-}"
      exit 0
      ;;
    backup)
      backup_create
      exit 0
      ;;
    restore)
      local file="${1:-}" force=0
      [ "${2:-}" = "--force" ] && force=1
      [ -n "$file" ] || die "Укажите архив: tg restore FILE [--force]"
      backup_restore "$file" "$force"
      exit 0
      ;;
    cluster)
      case "${1:-}" in
        status) cluster_cli_status; exit 0 ;;
        monitor) cluster_cli_monitor; exit 0 ;;
        panel-credentials) cluster_cli_panel_credentials; exit 0 ;;
        migrate-domain) cluster_cli_migrate_domain "${2:-}"; exit $? ;;
        *) die "tg cluster: status|monitor|panel-credentials|migrate-domain" ;;
      esac
      ;;
    "")
      return 0
      ;;
    *)
      die "Неизвестная команда: $SUBCOMMAND (doctor|link|backup|restore|cluster)"
      ;;
  esac
}

if [ -n "$SUBCOMMAND" ]; then
  dispatch_subcommand "$@"
fi

if [ "$STATUS" -eq 1 ]; then
  # shellcheck disable=SC1090
  [ -f "$STATE_FILE" ] && source "$STATE_FILE"
  show_proxy_status_panel
  exit 0
fi

if [ "$DOCTOR" -eq 1 ]; then
  env_load_settings 2>/dev/null || true
  run_doctor_full "${DOMAIN:-}"
  exit $?
fi

if [ "$MEKO_UPGRADE" -eq 1 ]; then
  if ! meko_is_inline_installed; then
    die "MEKO SYN FIX inline не установлен"
  fi
  if meko_update_available; then
    meko_upgrade_inline
  elif is_auto_mode; then
    meko_upgrade_inline
  else
    log_ok "MEKO SYN FIX уже актуален: v$(meko_installed_version)"
  fi
  exit 0
fi

if [ "$MEKO_BENCHMARK" -eq 1 ]; then
  meko_diag_run_benchmark
  exit 0
fi

if [ "$SPEEDTEST" -eq 1 ]; then
  run_speedtest "${SPEEDTEST_PROFILE:-quick}"
  exit $?
fi

if [ "$UNINSTALL" -eq 1 ]; then
  if ! is_auto_mode; then
    if [ "$PURGE" -eq 1 ]; then
      confirm_yes "ПОЛНОЕ удаление: секрет и SSL будут уничтожены. Продолжить?" || die "Отменено"
    else
      confirm_yes "Удалить установленный стек telemt-deploy?" || die "Удаление отменено"
    fi
  fi
  uninstall_all
  exit 0
fi

show_install_banner() {
  echo ""
  echo "=============================================="
  echo "  telemt-deploy - установка MTProxy"
  echo "=============================================="
  echo "  Ubuntu + telemt + nginx self-mask + MEKO"
  echo "  installer v${INSTALLER_VERSION}"
  echo "=============================================="
  echo ""
}

if has_action_flags; then
  show_install_banner
  case "$CLUSTER_ROLE" in
    master)
      prepare_cluster_domain
      if ! is_auto_mode; then
        confirm_yes "Инициализировать кластер ${CLUSTER_DOMAIN}?" || die "Отменено"
      fi
      run_cluster_master_init
      exit 0
      ;;
    master_lb|master-lb)
      prepare_cluster_domain
      run_cluster_master_lb_install
      exit 0
      ;;
    lb)
      prepare_cluster_domain
      if ! is_auto_mode; then
        confirm_yes "Установить LB для ${CLUSTER_DOMAIN}?" || die "Отменено"
      fi
      run_cluster_lb_install
      exit 0
      ;;
    node)
      set +e
      handle_existing_env
      set -euo pipefail
      prepare_install_domain
      prepare_cluster_domain
      prepare_install_options
      run_cluster_node_install
      exit 0
      ;;
  esac
  set +e
  handle_existing_env
  prepare_install_domain
  prepare_install_options
  run_install_flow
  flow_rc=$?
  set -euo pipefail
  [ "$flow_rc" -eq 0 ] || exit "$flow_rc"
  exit 0
fi

if ! [ -t 0 ] && [ -z "$SUBCOMMAND" ]; then
  die "Нет интерактивного терминала. Используйте: --help, --status, --doctor, tg link, ..."
fi

export MENU_MODE=1
set +e
main_menu
exit 0
