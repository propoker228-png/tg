#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DIALOG_SH_VERSION="1.0"

has_dialog() {
  command -v dialog >/dev/null 2>&1
}

has_tty() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

ui_reset_screen() {
  if has_tty; then
    if command -v tput >/dev/null 2>&1; then
      tput reset >/dev/tty 2>&1 || true
    fi
    clear >/dev/tty 2>&1 || true
    return 0
  fi
  clear 2>/dev/null || true
}

confirm_dialog() {
  local prompt="${1:-Продолжить?}"
  local rc=1

  if has_dialog && has_tty; then
    ui_reset_screen
    dialog --clear --backtitle "telemt-deploy" --yesno "$prompt" 12 72 </dev/tty >/dev/tty 2>&1
    rc=$?
    ui_reset_screen
    return "$rc"
  fi

  confirm_yes "$prompt"
}

confirm_action() {
  local prompt="${1:-Продолжить?}"
  if [ "${MENU_MODE:-0}" -eq 1 ] && has_dialog && has_tty; then
    confirm_dialog "$prompt"
  else
    confirm_yes "$prompt"
  fi
}
