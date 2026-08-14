#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# shellcheck source=../lib/speedtest.sh
source "$ROOT/lib/speedtest.sh"

r=$(speedtest_format_mbit 12500000 1)
[ "$r" = "100.0" ] && pass "format mbit 100" || fail "format mbit got=$r"

r=$(speedtest_profile_bytes quick)
[ "$r" = "10485760" ] && pass "profile quick bytes" || fail "quick bytes got=$r"

r=$(speedtest_profile_bytes full)
[ "$r" = "104857600" ] && pass "profile full bytes" || fail "full bytes got=$r"

out=$(printf '%s\n' '{"download":{"bandwidth":12500000},"upload":{"bandwidth":6250000},"ping":{"latency":12.4,"jitter":1.2},"server":{"name":"Test","location":"Amsterdam"},"isp":"Test ISP"}' | speedtest_parse_ookla_json)
echo "$out" | grep -q 'Download:.*100.0 Mbit/s' && pass "parse ookla download" || fail "parse ookla download"
echo "$out" | grep -q 'Upload:.*50.0 Mbit/s' && pass "parse ookla upload" || fail "parse ookla upload"
echo "$out" | grep -q 'Ping:.*12.4 ms' && pass "parse ookla ping" || fail "parse ookla ping"

mixed=$'progress: 50%\n{"download":{"bandwidth":12500000},"upload":{"bandwidth":6250000},"ping":{"latency":12.4,"jitter":1.2},"server":{"name":"Test","location":"Amsterdam"},"isp":"Test ISP"}\n'
extracted=$(printf '%s' "$mixed" | speedtest_extract_ookla_json)
[ -n "$extracted" ] && pass "extract ookla json from mixed output" || fail "extract ookla json"

exit "$FAIL"
