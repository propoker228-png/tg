#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export DEPLOY_ROOT="$ROOT"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/proxy_mode.sh
source "$ROOT/lib/proxy_mode.sh"

proxy_mode_default
[ "$PROXY_MODE" = "tls" ] && pass "default tls" || fail "default tls got=$PROXY_MODE"

PROXY_MODE=tls
normalize_proxy_mode "secure"
[ "$PROXY_MODE" = "secure" ] && pass "normalize secure" || fail "normalize secure"

PROXY_MODE=tls
normalize_proxy_mode "TLS"
[ "$PROXY_MODE" = "tls" ] && pass "normalize TLS case" || fail "normalize TLS case"

if ( PROXY_MODE=tls normalize_proxy_mode "bogus" ) >/dev/null 2>&1; then
  fail "reject bogus mode"
else
  pass "reject bogus mode"
fi

PROXY_MODE=secure
[ "$(proxy_mode_link_kind)" = "secure" ] && pass "link kind secure" || fail "link kind secure"
PROXY_MODE=tls
[ "$(proxy_mode_link_kind)" = "tls" ] && pass "link kind tls" || fail "link kind tls"

PROXY_MODE=secure
[[ "$(proxy_mode_label)" == *"dd"* ]] && pass "label secure" || fail "label secure"
PROXY_MODE=tls
[[ "$(proxy_mode_label)" == *"ee"* ]] && pass "label tls" || fail "label tls"

CLUSTER_ROLE=node
PROXY_MODE=secure
proxy_mode_force_tls_for_cluster
[ "$PROXY_MODE" = "tls" ] && pass "cluster forces tls" || fail "cluster forces tls"

render_telemt_tpl() {
  local mode="$1"
  PROXY_MODE="$mode"
  export PROXY_MODE DOMAIN=example.com TLS_DOMAIN=mask.example.com SECRET=0123456789abcdef0123456789abcdef AD_TAG_LINE=""
  export PUBLIC_HOST="$DOMAIN" TELEMT_TLS_DOMAIN="$TLS_DOMAIN"
  if [ "$mode" = "secure" ]; then
    export MODE_TLS=false MODE_SECURE=true TLS_EMULATION=true
  else
    export MODE_TLS=true MODE_SECURE=false TLS_EMULATION=false
  fi
  envsubst '${MODE_TLS} ${MODE_SECURE} ${PUBLIC_HOST} ${TELEMT_TLS_DOMAIN} ${TLS_EMULATION} ${SECRET} ${AD_TAG_LINE}' \
    < "$ROOT/templates/telemt.toml.tpl"
}

out=$(render_telemt_tpl secure)
echo "$out" | grep -q 'secure = true' && pass "tpl secure true" || fail "tpl secure true"
echo "$out" | grep -q 'tls = false' && pass "tpl tls false secure" || fail "tpl tls false secure"
echo "$out" | grep -q 'tls_emulation = true' && pass "tpl emulation secure" || fail "tpl emulation secure"

out=$(render_telemt_tpl tls)
echo "$out" | grep -q 'tls = true' && pass "tpl tls true" || fail "tpl tls true"
echo "$out" | grep -q 'secure = false' && pass "tpl secure false tls" || fail "tpl secure false tls"

# shellcheck source=../lib/link.sh
source "$ROOT/lib/link.sh"
export DOMAIN=example.com SECRET=0123456789abcdef0123456789abcdef TLS_DOMAIN=mask.example.com
PROXY_MODE=secure
out=$(build_proxy_link_fallback)
[[ "$out" == *"secret=dd0123456789abcdef0123456789abcdef" ]] && pass "fallback dd" || fail "fallback dd got=$out"
[[ "$out" != *"mask.example"* ]] && pass "fallback dd no domain hex" || fail "fallback dd no domain hex"

PROXY_MODE=tls
out=$(build_proxy_link_fallback)
[[ "$out" == tg://proxy?server=example.com* ]] && pass "fallback tls prefix" || fail "fallback tls"
[[ "$out" == *"secret=ee"* ]] && pass "fallback ee" || fail "fallback ee"

exit "$FAIL"
