#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export ACCESS_LIMITS_CONFIG_FILE="$ROOT/.tmp-access-limits-test/access-limits.json"
mkdir -p "$(dirname "$ACCESS_LIMITS_CONFIG_FILE")"
rm -f "$ACCESS_LIMITS_CONFIG_FILE"

# shellcheck source=../lib/access_limits.sh
source "$ROOT/lib/access_limits.sh"

r=$(access_limits_derive_tcp_conns 5)
[ "$r" = "25" ] && pass "derive tcp 5 devices" || fail "derive tcp got=$r"

r=$(access_limits_derive_tcp_conns 1)
[ "$r" = "5" ] && pass "derive tcp min clamp" || fail "derive tcp min got=$r"

access_limits_save_config 1 5 5 25 1
access_limits_load_config
[ "${ACCESS_LIMITS_ENABLED:-0}" -eq 1 ] && pass "save/load enabled" || fail "enabled"
[ "${ACCESS_LIMITS_MAX_TCP_CONNS:-0}" -eq 25 ] && pass "save/load tcp" || fail "tcp"

access_limits_validate_positive_int 5 || fail "validate positive"
access_limits_validate_tcp_conns 4 && fail "reject tcp<5"
access_limits_validate_tcp_conns 5 || fail "accept tcp=5"

exit "$FAIL"
