#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/ui_highlight.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/role_wizard.sh"

export DEPLOY_ROOT="$ROOT"

out=$(mask_secret_hex "0123456789abcdef0123456789abcdef")
if [ "$out" = "0123...cdef" ]; then
  pass "mask_secret_hex"
else
  fail "mask_secret_hex got: $out"
fi

CLUSTER_ROLE=node
CLUSTER_DOMAIN="proxy.example.com"
DOMAIN="mask.example.com"
INSTALL_IP_ONLY=0
SECRET="0123456789abcdef0123456789abcdef"
summary=$(print_role_summary "node")
echo "$summary" | grep -q "proxy.example.com" && pass "print_role_summary cluster domain" \
  || fail "print_role_summary cluster domain"

is_valid_cluster_secret_hex "0123456789abcdef0123456789abcdef" && pass "secret hex valid" \
  || fail "secret hex valid"
! is_valid_cluster_secret_hex "short" && pass "secret hex invalid" || fail "secret hex invalid"

[ "$FAIL" -eq 0 ] && echo "ALL ROLE WIZARD SMOKE OK" || exit 1
