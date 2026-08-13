#!/bin/bash
set -euo pipefail

TABLE="${ZAPRET2_NFT_TABLE}"
FWMARK="0x40000000"
PORT="${PROXY_PORT}"
QNUM="${ZAPRET2_QNUM}"
CT_MARK="0x00040000"
COMBINED_MARK="0x40040000"
BYPASS_MATCH="tcp flags & (fin | syn | rst | ack) == ack"
BIN="${ZAPRET2_DIR}/bin/nfqws2"
CONF="${ZAPRET2_ETC_DIR}/mtproto.conf"

sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true

nft delete table ip "$TABLE" 2>/dev/null || true
nft add table ip "$TABLE"

nft "add chain ip $TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip $TABLE predefrag meta mark $COMBINED_MARK counter accept"
nft "add rule ip $TABLE predefrag meta mark and $FWMARK != 0x00000000 counter notrack"

nft "add chain ip $TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip $TABLE output meta mark and $COMBINED_MARK == $COMBINED_MARK ct mark set $CT_MARK counter accept"

nft "add chain ip $TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
nft "add rule ip $TABLE postrouting $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE postrouting meta mark and $FWMARK == 0x00000000 tcp sport $PORT counter queue num $QNUM bypass"

nft "add chain ip $TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add rule ip $TABLE prerouting ct state invalid counter drop"
nft "add rule ip $TABLE prerouting $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip $TABLE prerouting meta mark and $FWMARK == 0x00000000 tcp dport $PORT counter queue num $QNUM bypass"

echo "NFT table $TABLE applied (port=$PORT qnum=$QNUM)"
exec "$BIN" @"$CONF"
