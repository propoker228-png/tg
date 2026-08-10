#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export SHAPING_CONFIG_FILE="$ROOT/.tmp-shaping-test/shaping.json"
mkdir -p "$(dirname "$SHAPING_CONFIG_FILE")"
rm -f "$SHAPING_CONFIG_FILE"

# shellcheck source=../lib/shaping.sh
source "$ROOT/lib/shaping.sh"

r=$(shaping_effective_limit "203.0.113.10" 1 50 '{}')
[ "$r" = "50" ] && pass "global limit" || fail "global limit got=$r"

r=$(shaping_effective_limit "203.0.113.10" 1 50 '{"203.0.113.10":100}')
[ "$r" = "100" ] && pass "override custom" || fail "override custom got=$r"

r=$(shaping_effective_limit "203.0.113.10" 1 50 '{"203.0.113.10":null}')
[ "$r" = "unlimited" ] && pass "override unlimited" || fail "override unlimited got=$r"

r=$(shaping_effective_limit "203.0.113.10" 0 50 '{}')
[ "$r" = "unlimited" ] && pass "disabled" || fail "disabled got=$r"

r=$(shaping_effective_limit "203.0.113.10" 1 0 '{}')
[ "$r" = "unlimited" ] && pass "global zero" || fail "global zero got=$r"

[ "$(shaping_mbit_to_tc_rate 50)" = "50mbit" ] && pass "tc rate" || fail "tc rate"

shaping_validate_mbit "10" && pass "valid mbit" || fail "valid mbit"
! shaping_validate_mbit "-1" && pass "reject negative" || fail "reject negative"
! shaping_validate_mbit "abc" && pass "reject abc" || fail "reject abc"

shaping_save_config 1 50 '{"203.0.113.10":100}'
shaping_load_config
[ "${SHAPING_ENABLED:-0}" -eq 1 ] && [ "${SHAPING_GLOBAL_MBIT:-0}" = "50" ] && pass "config round-trip" || fail "config round-trip"

shaping_override_set_unlimited "198.51.100.5"
shaping_load_config
r=$(shaping_effective_limit "198.51.100.5" "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON")
[ "$r" = "unlimited" ] && pass "override save unlimited" || fail "override save unlimited got=$r"

shaping_override_remove "198.51.100.5"
! shaping_has_override "198.51.100.5" && pass "override remove" || fail "override remove"

rm -rf "$(dirname "$SHAPING_CONFIG_FILE")"
exit "$FAIL"
