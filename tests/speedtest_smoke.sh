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

out=$(printf '%s\n' '{"download":{"bandwidth":12500000},"upload":{"bandwidth":6250000},"ping":{"latency":12.4,"jitter":1.2},"server":{"name":"Test","location":"Amsterdam"},"isp":"Test ISP"}' | speedtest_parse_json)
echo "$out" | grep -q 'Download:.*100.0 Mbit/s' && pass "parse ookla download" || fail "parse ookla download"
echo "$out" | grep -q 'Upload:.*50.0 Mbit/s' && pass "parse ookla upload" || fail "parse ookla upload"
echo "$out" | grep -q 'Ping:.*12.4 ms' && pass "parse ookla ping" || fail "parse ookla ping"

legacy='{"download":100000000,"upload":50000000,"ping":12.4,"server":{"name":"Amsterdam","country":"Netherlands"},"client":{"isp":"Test ISP"}}'
out=$(printf '%s\n' "$legacy" | speedtest_parse_json)
echo "$out" | grep -q 'Download:.*100.0 Mbit/s' && pass "parse legacy download" || fail "parse legacy download"
echo "$out" | grep -q 'Upload:.*50.0 Mbit/s' && pass "parse legacy upload" || fail "parse legacy upload"
echo "$out" | grep -q 'Ping:.*12.4 ms' && pass "parse legacy ping" || fail "parse legacy ping"
echo "$out" | grep -q 'ISP:.*Test ISP' && pass "parse legacy isp" || fail "parse legacy isp"

mixed=$'progress: 50%\n{"download":{"bandwidth":12500000},"upload":{"bandwidth":6250000},"ping":{"latency":12.4,"jitter":1.2},"server":{"name":"Test","location":"Amsterdam"},"isp":"Test ISP"}\n'
extracted=$(printf '%s' "$mixed" | speedtest_extract_json)
[ -n "$extracted" ] && pass "extract json from mixed output" || fail "extract json"

r=$(speedtest_profile_upload_mb quick)
[ "$r" = "10" ] && pass "profile quick upload mb" || fail "quick upload mb got=$r"

r=$(speedtest_profile_upload_mb full)
[ "$r" = "25" ] && pass "profile full upload mb" || fail "full upload mb got=$r"

exit "$FAIL"
