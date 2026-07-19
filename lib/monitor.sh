#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MONITOR_SH_VERSION="1.1"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-4}"

MONITOR_NET_IFACE=""
MONITOR_NET_RX_PREV=0
MONITOR_NET_TX_PREV=0
MONITOR_NET_RX_PKT_PREV=0
MONITOR_NET_TX_PKT_PREV=0
MONITOR_NET_TS_PREV=0

monitor_default_iface() {
  local iface=""
  iface=$(ip route show default 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
  }')
  if [ -n "$iface" ] && [ -d "/sys/class/net/${iface}" ]; then
    printf '%s' "$iface"
    return 0
  fi
  for iface in eth0 ens3 enp0s3 eno1; do
    if [ -d "/sys/class/net/${iface}" ]; then
      printf '%s' "$iface"
      return 0
    fi
  done
  ip -o link show up 2>/dev/null | awk -F': ' '!/ lo:| docker| br-| veth/ {print $2; exit}'
}

monitor_iface_counter() {
  local iface="$1" counter="$2"
  local path="/sys/class/net/${iface}/statistics/${counter}"
  [ -r "$path" ] || return 1
  tr -d '[:space:]' < "$path"
}

monitor_reset_network_stats() {
  MONITOR_NET_IFACE="$(monitor_default_iface)"
  MONITOR_NET_RX_PREV=0
  MONITOR_NET_TX_PREV=0
  MONITOR_NET_RX_PKT_PREV=0
  MONITOR_NET_TX_PKT_PREV=0
  MONITOR_NET_TS_PREV=0
}

monitor_format_bytes_short() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GiB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MiB", b / 1048576
    else if (b >= 1024) printf "%.1f KiB", b / 1024
    else printf "%d B", b
  }'
}

monitor_format_bitrate() {
  local bps="$1"
  awk -v b="$bps" 'BEGIN {
    if (b >= 1000000000) printf "%.2f Gbit/s", b / 1000000000
    else if (b >= 1000000) printf "%.1f Mbit/s", b / 1000000
    else if (b >= 1000) printf "%.1f Kbit/s", b / 1000
    else printf "%d bit/s", b
  }'
}

monitor_format_pps() {
  local pps="$1"
  awk -v p="$pps" 'BEGIN {
    if (p >= 1000000) printf "%.2f Mpps", p / 1000000
    else if (p >= 1000) printf "%.1f Kpps", p / 1000
    else printf "%.0f pps", p
  }'
}

monitor_render_network_panel() {
  local iface rx tx rx_pkt tx_pkt now dt rx_bps tx_bps rx_pps tx_pps
  local estab_443 syn_recv rx_human tx_human

  iface="${MONITOR_NET_IFACE:-$(monitor_default_iface)}"
  MONITOR_NET_IFACE="$iface"

  if [ -z "$iface" ] || [ ! -d "/sys/class/net/${iface}" ]; then
    log_warn "Сетевой интерфейс не найден"
    return 1
  fi

  rx=$(monitor_iface_counter "$iface" rx_bytes || echo 0)
  tx=$(monitor_iface_counter "$iface" tx_bytes || echo 0)
  rx_pkt=$(monitor_iface_counter "$iface" rx_packets || echo 0)
  tx_pkt=$(monitor_iface_counter "$iface" tx_packets || echo 0)
  now=$(date +%s)

  echo -e "  ${BOLD}Сеть (${iface})${NC}"
  if [ "$MONITOR_NET_TS_PREV" -gt 0 ]; then
    dt=$((now - MONITOR_NET_TS_PREV))
    [ "$dt" -lt 1 ] && dt=1
    rx_bps=$(( (rx - MONITOR_NET_RX_PREV) * 8 / dt ))
    tx_bps=$(( (tx - MONITOR_NET_TX_PREV) * 8 / dt ))
    rx_pps=$(( (rx_pkt - MONITOR_NET_RX_PKT_PREV) / dt ))
    tx_pps=$(( (tx_pkt - MONITOR_NET_TX_PKT_PREV) / dt ))
    rx_human=$(monitor_format_bytes_short $(( (rx - MONITOR_NET_RX_PREV) / dt )) )
    tx_human=$(monitor_format_bytes_short $(( (tx - MONITOR_NET_TX_PREV) / dt )) )

    echo -e "    ${CYAN}↓ RX${NC}  $(monitor_format_bitrate "$rx_bps")  (${rx_human}/s)  $(monitor_format_pps "$rx_pps")"
    echo -e "    ${CYAN}↑ TX${NC}  $(monitor_format_bitrate "$tx_bps")  (${tx_human}/s)  $(monitor_format_pps "$tx_pps")"
  else
    echo -e "    ${GRAY}измерение скорости...${NC}"
  fi

  echo -e "    ${GRAY}с загрузки:${NC} RX $(monitor_format_bytes_short "$rx")  |  TX $(monitor_format_bytes_short "$tx")"

  estab_443=$(ss -H -tn state established "( sport = :443 )" 2>/dev/null | wc -l | tr -d '[:space:]')
  syn_recv=$(ss -H -tn state syn-recv "( sport = :443 )" 2>/dev/null | wc -l | tr -d '[:space:]')
  echo -e "    ${GRAY}:443${NC}  ESTAB: ${YELLOW}${estab_443:-0}${NC}  |  SYN-recv: ${syn_recv:-0}"
  echo ""

  MONITOR_NET_RX_PREV=$rx
  MONITOR_NET_TX_PREV=$tx
  MONITOR_NET_RX_PKT_PREV=$rx_pkt
  MONITOR_NET_TX_PKT_PREV=$tx_pkt
  MONITOR_NET_TS_PREV=$now
}

run_live_monitor() {
  local key=""
  trap 'clear; trap - INT; return 0' INT
  monitor_reset_network_stats
  while true; do
    clear
    render_menu_header "${INSTALLER_VERSION:-2.4}"
    monitor_render_network_panel
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
