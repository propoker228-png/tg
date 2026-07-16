#!/bin/bash
# telemt-deploy — установка telemt + nginx self-mask + MEKO SYN FIX
#
# Использование: sudo bash install.sh [флаги]
#
# Без флагов — интерактивное меню управления (п. 1–11).
#
#   --domain DOMAIN         Домен (A-запись → этот сервер)
#   --ad-tag HEX32          ad_tag из @MTProxybot (32 hex)
#   --telemt-version VER    Версия telemt (например 3.4.23)
#   --meko-full             Полный MEKO Launcher вместо inline SYN fix
#   --yes                   Авто-подтверждение (DNS, удаление, новая версия telemt)
#   --fresh                 Удалить найденную установку и поставить с нуля (без вопросов)
#   --keep                  Оставить найденную установку как есть (без вопросов)
#   --status                Показать статус и число подключённых (как в MEKO)
#   --meko-upgrade          Обновить MEKO SYN FIX до версии из комплекта
#   --uninstall             Удалить установленный стек
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

DOMAIN=""; AD_TAG=""; TELEMT_VERSION=""; YES=0; MEKO_FULL=0; UNINSTALL=0
FRESH=0; KEEP_EXISTING=0; STATUS=0; MEKO_UPGRADE=0

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
    --ad-tag) AD_TAG=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --telemt-version) TELEMT_VERSION=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
    --meko-full) MEKO_FULL=1; shift ;;
    --yes) YES=1; shift ;;
    --fresh|--reinstall) FRESH=1; shift ;;
    --keep|--keep-existing) KEEP_EXISTING=1; shift ;;
    --status) STATUS=1; shift ;;
    --meko-upgrade) MEKO_UPGRADE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $1" >&2
      exit 1
      ;;
  esac
done

export TELEMT_VERSION MEKO_FULL YES FRESH KEEP_EXISTING MEKO_UPGRADE
[ -n "$AD_TAG" ] && export AD_TAG

remote_bootstrap

# shellcheck source=lib/common.sh
source "$DEPLOY_ROOT/lib/common.sh"
for mod in prereq dns nginx ssl telemt meko firewall dialog verify handoff uninstall env stats monitor install_flow cli_tools menu; do
  # shellcheck source=/dev/null
  source "$DEPLOY_ROOT/lib/${mod}.sh"
done

if [ "$FRESH" -eq 1 ] && [ "$KEEP_EXISTING" -eq 1 ]; then
  die "Нельзя одновременно использовать --fresh и --keep"
fi

validate_cli_inputs() {
  if [ -n "$DOMAIN" ]; then
    DOMAIN="$(require_valid_domain_name "$DOMAIN")"
    export DOMAIN
  fi
  [ -z "$AD_TAG" ] || require_valid_ad_tag "$AD_TAG"
  [ -z "$TELEMT_VERSION" ] || require_valid_telemt_version "$TELEMT_VERSION"
}

validate_cli_inputs

INSTALLER_VERSION="2.4"

on_err() {
  echo "[X] Сбой установки (строка ${1:-?} в ${2:-install.sh})" >&2
  exit 1
}

trap 'on_err $LINENO ${BASH_SOURCE[0]##*/}' ERR

has_action_flags() {
  [ "$UNINSTALL" -eq 1 ] || [ "$STATUS" -eq 1 ] || [ "$FRESH" -eq 1 ] || \
    [ "$KEEP_EXISTING" -eq 1 ] || [ "$MEKO_UPGRADE" -eq 1 ] || [ -n "$DOMAIN" ] || \
    [ -n "$AD_TAG" ] || [ -n "$TELEMT_VERSION" ] || [ "$MEKO_FULL" -eq 1 ]
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
  if [ "${MONITOR_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/monitor.sh (v1.0) — скопируйте lib/monitor.sh на сервер" >&2
    missing=1
  fi
  if [ "${DIALOG_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/dialog.sh (v1.0) — скопируйте lib/dialog.sh на сервер" >&2
    missing=1
  fi
  if [ "${INSTALL_FLOW_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/install_flow.sh (v1.0) — скопируйте lib/install_flow.sh на сервер" >&2
    missing=1
  fi
  if [ "${MEKO_SH_VERSION:-}" != "1.1" ]; then
    echo "[X] Устаревший lib/meko.sh (нужен v1.1) — скопируйте lib/meko.sh на сервер" >&2
    missing=1
  fi
  if [ "${CLI_TOOLS_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/cli_tools.sh (v1.0) — скопируйте lib/cli_tools.sh на сервер" >&2
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

if [ "$STATUS" -eq 1 ]; then
  # shellcheck disable=SC1090
  [ -f "$STATE_FILE" ] && source "$STATE_FILE"
  show_proxy_status_panel
  exit 0
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

if [ "$UNINSTALL" -eq 1 ]; then
  if ! is_auto_mode; then
    confirm_yes "Удалить установленный стек telemt-deploy?" || die "Удаление отменено"
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
  set +e
  handle_existing_env
  set -euo pipefail
  prepare_install_domain
  run_install_flow
  exit 0
fi

if ! [ -t 0 ]; then
  die "Нет интерактивного терминала. Используйте флаги: --help, --status, --domain, --uninstall"
fi

export MENU_MODE=1
set +e
main_menu
exit 0
