#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=meko_stats.sh
source "$(dirname "${BASH_SOURCE[0]}")/meko_stats.sh"
# shellcheck source=meko.sh
source "$(dirname "${BASH_SOURCE[0]}")/meko.sh"

MEKO_DIAG_SH_VERSION="1.0"

meko_diag_show_config() {
  local rate="${MEKO_HASHLIMIT_RATE:-54/minute}" burst="${MEKO_HASHLIMIT_BURST:-1}"
  if [ -f /etc/default/mtpr-synfix ]; then
    # shellcheck disable=SC1091
    source /etc/default/mtpr-synfix
    rate="${MEKO_HASHLIMIT_RATE:-$rate}"
    burst="${MEKO_HASHLIMIT_BURST:-$burst}"
  fi
  echo "  hashlimit: ${rate}, burst=${burst}"
  echo "  MEKO версия: v$(meko_installed_version 2>/dev/null || echo ?)"
}

meko_diag_show_counters() {
  local accept=0 reject=0 pct=""
  read -r accept reject <<< "$(meko_stats_syn_counts 2>/dev/null || echo "0 0")"
  echo "  SYN ACCEPT: ${accept}, REJECT: ${reject}"
  if pct=$(meko_stats_accept_pct 2>/dev/null); then
    echo "  Доля ACCEPT: ${pct}%"
  else
    echo "  Доля ACCEPT: н/д (нет SYN-трафика на 443)"
  fi
}

meko_diag_run_benchmark() {
  local burst pct
  echo ""
  echo -e "${BOLD}=== MEKO SYN FIX — диагностика / benchmark ===${NC}"
  echo ""
  meko_diag_show_config
  meko_diag_show_counters
  echo ""

  burst="$(meko_stats_hashlimit_burst)"
  if [ "${burst:-1}" != "1" ]; then
    log_warn "burst=${burst} — без A/B-теста с клиентской сети риск блокировки DPI (~30 с)"
    log_info "Откат: sudo rm -f /etc/default/mtpr-synfix && sudo bash install.sh --meko-upgrade"
  fi

  if pct=$(meko_stats_accept_pct 2>/dev/null); then
    if [ "$pct" -lt 70 ]; then
      log_warn "Низкая доля ACCEPT (${pct}%) — проверьте burst=1 и подключение с клиента"
    else
      log_ok "Доля ACCEPT ${pct}% — hashlimit в норме"
    fi
  fi

  echo ""
  echo "Рекомендации для Obfuscated2 (dd):"
  echo "  • burst=1, rate=54/minute (по умолчанию)"
  echo "  • Не повышайте burst без A/B-теста с реальной сети клиента"
  echo "  • Полный A/B: сравните время подключения Telegram при burst=1 vs burst=3"
  echo ""
}
