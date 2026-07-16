#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

check_syntax() {
  local f="$1"
  if bash -n "$f"; then
    echo "OK syntax: $f"
  else
    echo "FAIL syntax: $f"
    FAIL=1
  fi
}

check_cmd_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "OK check: $name"
  else
    echo "FAIL check: $name"
    FAIL=1
  fi
}

check_cmd_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL check: $name"
    FAIL=1
  else
    echo "OK check: $name"
  fi
}

check_helpers() {
  (
    # shellcheck source=../lib/common.sh
    source "$ROOT/lib/common.sh"
    is_valid_domain_name "example.com"
    is_valid_domain_name "sub.example.co"
    is_valid_domain_name "rknmylove.botrkn.cloud-ip.cc"
    [ "$(normalize_domain_name " Example.COM. ")" = "example.com" ]
    [ "$(require_valid_domain_name "rknmylove.botrkn.cloud-ip.cc ")" = "rknmylove.botrkn.cloud-ip.cc" ]
    ! is_valid_domain_name "bad_domain"
    ! is_valid_domain_name "-bad.example.com"
    is_valid_ad_tag "13ea0123456789abcdef0123456789ab"
    ! is_valid_ad_tag "not-a-tag"
    is_valid_telemt_version "3.4.23"
    ! is_valid_telemt_version "latest"
    version_gt "3.4.24" "3.4.23"
    ! version_gt "3.4.23" "3.4.23"
  )
}

check_confirm_action_cli_fallback() {
  (
    # shellcheck source=../lib/dialog.sh
    source "$ROOT/lib/dialog.sh"
    MENU_MODE=0
    YES=1
    confirm_action "test prompt"
  )
}

check_prompt_stdout_clean() {
  (
    # shellcheck source=../lib/common.sh
    source "$ROOT/lib/common.sh"
    [ -z "$(prompt_msg "PROMPT_STDOUT_TEST")" ]
  )
}

check_resolve_explicit_version() {
  (
    # shellcheck source=../lib/telemt.sh
    source "$ROOT/lib/telemt.sh"
    TELEMT_VERSION="3.4.23"
    [ "$(resolve_telemt_version)" = "3.4.23" ]
  )
}

check_menu_keep_stops_install() {
  (
    # shellcheck source=../lib/menu.sh
    source "$ROOT/lib/menu.sh"
    handle_existing_env() {
      SELECTED_ENV_ACTION="keep"
    }
    pause_key_menu() {
      :
    }
    prepare_install_domain() {
      return 42
    }
    run_install_flow() {
      return 43
    }
    menu_install
  )
}

check_meko_version_helpers() {
  (
    # shellcheck source=../lib/meko.sh
    source "$ROOT/lib/meko.sh"
    local tmp="$ROOT/.tmp-smoke-meko"
    [ "$(meko_bundled_version)" = "3.0.1" ]
    version_gt "3.0.1" "3.0.0"
    mkdir -p "$tmp"
    MEKO_VERSION_FILE="$tmp/version"
    MEKO_APPLY_SCRIPT="$tmp/apply-mtpr-synfix.sh"
    touch "$MEKO_APPLY_SCRIPT"
    echo "3.0.0" > "$MEKO_VERSION_FILE"
    meko_update_available
    echo "3.0.1" > "$MEKO_VERSION_FILE"
    ! meko_update_available
    rm -rf "$tmp"
  )
}

check_tg_template() {
  grep -q '@DEPLOY_ROOT@' "$ROOT/templates/tg"
}

for f in "$ROOT/install.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/smoke.sh "$ROOT/templates/tg"; do
  [ -f "$f" ] && check_syntax "$f"
done

check_cmd_ok "common helper validators" check_helpers
check_cmd_ok "meko version helpers" check_meko_version_helpers
check_cmd_ok "tg template present" check_tg_template
check_cmd_ok "confirm_action cli fallback" check_confirm_action_cli_fallback
check_cmd_ok "prompts do not leak to stdout" check_prompt_stdout_clean
check_cmd_ok "explicit telemt version resolver" check_resolve_explicit_version
check_cmd_ok "menu keep stops install flow" check_menu_keep_stops_install
check_cmd_fail "missing --domain value" bash "$ROOT/install.sh" --domain
check_cmd_fail "invalid --domain value" bash "$ROOT/install.sh" --domain bad_domain
check_cmd_fail "missing --ad-tag value" bash "$ROOT/install.sh" --ad-tag
check_cmd_fail "invalid --ad-tag value" bash "$ROOT/install.sh" --ad-tag not-a-tag
check_cmd_fail "invalid --telemt-version value" bash "$ROOT/install.sh" --telemt-version latest

[ "$FAIL" -eq 0 ] && echo "ALL SYNTAX OK" || exit 1
