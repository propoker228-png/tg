#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export DEPLOY_ROOT="$ROOT"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/meko_stats.sh
source "$ROOT/lib/meko_stats.sh"

sample='    pkts      bytes target     prot opt in     out     source               destination
       100        0 ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:443 flags:0x17/0x02 mark match 0x400
       800        0 ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:443 flags:0x17/0x02 limit: avg 54/min burst 1
        50        0 REJECT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:443 flags:0x17/0x02 reject-with tcp-reset'

read -r accept reject <<< "$(meko_stats_parse_chain_text "$sample")"
[ "$accept" = "900" ] && pass "parse accept" || fail "parse accept got=$accept"
[ "$reject" = "50" ] && pass "parse reject" || fail "parse reject got=$reject"

[ "$(meko_stats_hashlimit_burst)" = "1" ] && pass "burst default" || fail "burst default got=$(meko_stats_hashlimit_burst)"

exit "$FAIL"
