#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MEKO_STATS_SH_VERSION="1.0"
MEKO_SYNFIX_CHAIN="${MEKO_SYNFIX_CHAIN:-MTPR_SYNFIX}"

# Parse iptables -L output (pkts bytes target ...). Prints: accept_pkts reject_pkts
meko_stats_parse_chain_text() {
  local text="${1:-}"
  awk '
    /^[[:space:]]*[0-9]+/ {
      pkts = $1 + 0
      target = $3
      if (target == "ACCEPT" && $0 ~ /flags:0x17\/0x02/) accept += pkts
      if (target == "REJECT" && $0 ~ /flags:0x17\/0x02/) reject += pkts
    }
    END { printf "%d %d\n", accept + 0, reject + 0 }
  ' <<< "$text"
}

meko_stats_syn_counts() {
  local text accept=0 reject=0
  if ! command -v iptables >/dev/null 2>&1; then
    echo "0 0"
    return 1
  fi
  text=$(iptables -L "$MEKO_SYNFIX_CHAIN" -v -n -x 2>/dev/null || true)
  [ -n "$text" ] || { echo "0 0"; return 1; }
  read -r accept reject <<< "$(meko_stats_parse_chain_text "$text")"
  echo "$accept $reject"
}

# Prints accept_pct (0-100) or empty if no data
meko_stats_accept_pct() {
  local accept=0 reject=0 total
  read -r accept reject <<< "$(meko_stats_syn_counts 2>/dev/null || echo "0 0")"
  total=$((accept + reject))
  [ "$total" -gt 0 ] || return 1
  echo $((accept * 100 / total))
}

meko_stats_hashlimit_burst() {
  local burst=""
  if [ -f /etc/default/mtpr-synfix ]; then
    # shellcheck disable=SC1091
    source /etc/default/mtpr-synfix
    burst="${MEKO_HASHLIMIT_BURST:-}"
  fi
  printf '%s' "${burst:-1}"
}
