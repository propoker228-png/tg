#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SNI_CHECK_SH_VERSION="1.0"

telemt_tls_domain() {
  if [ -f /etc/telemt/telemt.toml ]; then
    awk -F'"' '/^tls_domain = / { print $2; exit }' /etc/telemt/telemt.toml 2>/dev/null
    return 0
  fi
  printf '%s' "${DOMAIN:-}"
}

check_sni_local() {
  local sni="${1:-$(telemt_tls_domain)}"
  local out rc=1

  [ -n "$sni" ] || return 2
  command -v openssl >/dev/null 2>&1 || return 2

  out=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 \
    -servername "$sni" 2>/dev/null | head -20)
  if echo "$out" | grep -qiE 'CONNECTED|Verify return code'; then
    return 0
  fi
  return 1
}
