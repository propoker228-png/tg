#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_STEP_SH_VERSION="1.0"
INSTALL_SKIPPED_STEPS=()

install_step_interactive() {
  ! is_auto_mode && has_tty
}

install_step_reset() {
  INSTALL_SKIPPED_STEPS=()
}

install_step_skipped() {
  local id="$1" item
  for item in "${INSTALL_SKIPPED_STEPS[@]}"; do
    [ "$item" = "$id" ] && return 0
  done
  return 1
}

install_step_run_once() {
  set +e
  ("$@")
  local rc=$?
  set -euo pipefail
  return "$rc"
}

install_step_fail_action() {
  local step_label="$1" skippable="$2" choice=""

  echo ""
  log_err "Этап «${step_label}» завершился с ошибкой"
  echo ""
  echo "  1) Повторить этот этап"
  [ "$skippable" = "1" ] && echo "  2) Пропустить этап и продолжить"
  echo "  3) Вернуться на предыдущий этап"
  echo "  0) Прервать установку"

  while true; do
    prompt_line choice "Выбор" "1"
    case "$choice" in
      1|retry|повтор) printf '%s' "retry"; return 0 ;;
      2|skip|пропустить)
        if [ "$skippable" = "1" ]; then
          printf '%s' "skip"
          return 0
        fi
        log_warn "Этот этап нельзя пропустить"
        ;;
      3|back|назад) printf '%s' "back"; return 0 ;;
      0|abort|q|Q|exit|выход) printf '%s' "abort"; return 0 ;;
      *) log_warn "Неверный выбор" ;;
    esac
  done
}

# Запускает команду/функцию в subshell (die внутри не роняет весь скрипт).
# Возврат: 0 — успех, 1 — прервать установку, 2 — шаг назад.
install_step_run() {
  local step_id="$1" step_label="$2" skippable="${3:-0}"
  shift 3
  local action="" rc=0

  while true; do
    if install_step_run_once "$@"; then
      return 0
    fi
    rc=$?

    if ! install_step_interactive; then
      log_err "Этап «${step_label}» завершился с ошибкой (код ${rc})"
      return 1
    fi

    action=$(install_step_fail_action "$step_label" "$skippable")
    case "$action" in
      retry) continue ;;
      skip)
        log_warn "Пропущен этап: ${step_label}"
        INSTALL_SKIPPED_STEPS+=("$step_id")
        return 0
        ;;
      back) return 2 ;;
      abort) return 1 ;;
    esac
  done
}

install_step_show_skipped_summary() {
  [ "${#INSTALL_SKIPPED_STEPS[@]}" -gt 0 ] || return 0
  log_warn "Пропущены этапы: ${INSTALL_SKIPPED_STEPS[*]}"
}
