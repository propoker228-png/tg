#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MONITOR_SH_VERSION="1.0"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-4}"

run_live_monitor() {
  local key=""
  trap 'clear; trap - INT; return 0' INT
  while true; do
    clear
    render_menu_header "${INSTALLER_VERSION:-2.4}"
    echo "  Обновление каждые ${MONITOR_INTERVAL}s | q или 0 = выход"
    echo ""
    if read -rsn1 -t "$MONITOR_INTERVAL" key </dev/tty 2>/dev/null; then
      case "$key" in
        q|Q|0) break ;;
      esac
    fi
  done
  trap - INT
  clear
}
