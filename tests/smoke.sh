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
    is_valid_meko_version "3.0.1"
    is_valid_meko_version "0.19"
    ! is_valid_meko_version "latest"
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

check_parse_release_versions() {
  (
    # shellcheck source=../lib/version_picker.sh
    source "$ROOT/lib/version_picker.sh"
    local json='[{"tag_name":"v3.4.22"},{"tag_name":"v3.4.24"},{"tag_name":"v3.4.23"}]'
    local out
    out=$(parse_release_versions_from_json "$json" 3)
    [ "$(printf '%s\n' "$out" | sed -n '1p')" = "3.4.24" ]
    [ "$(printf '%s\n' "$out" | sed -n '3p')" = "3.4.22" ]
  )
}

check_install_summary_render() {
  (
    # shellcheck source=../lib/meko.sh
    source "$ROOT/lib/meko.sh"
    # shellcheck source=../lib/ui_highlight.sh
    source "$ROOT/lib/ui_highlight.sh"
    DOMAIN="example.com"
    TELEMT_VERSION="3.4.24"
    MEKO_VERSION="3.0.1"
    MEKO_FULL=0
    TELEMT_VERSION_HINT="★ latest"
    out=$(print_install_summary)
    [[ "$out" == *"example.com"* ]]
    [[ "$out" == *"3.4.24"* ]]
    [[ "$out" == *"3.0.1"* ]]
  )
}

check_backup_manifest_paths() {
  (
    DOMAIN="example.com"
    SECRET_FILE="/root/telemt-secret.txt"
    STATE_FILE="/root/telemt-deploy.state"
    # shellcheck source=../lib/backup.sh
    source "$ROOT/lib/backup.sh"
    backup_collect_paths "example.com"
    [ "${#BACKUP_PATHS[@]}" -ge 1 ]
    paths=$(backup_manifest_paths_json "example.com")
    echo "$paths" | jq -e '. | length >= 1' >/dev/null
  )
}

check_doctor_aggregate() {
  (
    # shellcheck source=../lib/doctor.sh
    source "$ROOT/lib/doctor.sh"
    doctor_reset
    doctor_record "test pass" pass
    doctor_record "test fail" fail
    [ "$DOCTOR_TOTAL" -eq 2 ] && [ "$DOCTOR_FAILED" -eq 1 ]
  )
}

check_rkn_ip_lookup() {
  (
    # shellcheck source=../lib/rkn_check.sh
    source "$ROOT/lib/rkn_check.sh"
    local tmp="$ROOT/.tmp-smoke-rkn"
    mkdir -p "$tmp"
    printf '%s\n' '["90.156.254.235","10.0.0.0/8"]' > "$tmp/cache.json"
    [ "$(rkn_lookup_ip_in_cache "90.156.254.235" "$tmp/cache.json")" = "BLOCKED" ]
    [ "$(rkn_lookup_ip_in_cache "8.8.8.8" "$tmp/cache.json")" = "FREE" ]
    rm -rf "$tmp"
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
    prepare_install_options() {
      return 44
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

check_cmd_ok "backup manifest paths" check_backup_manifest_paths
check_cmd_ok "doctor aggregate counters" check_doctor_aggregate
check_cmd_ok "rkn ip cache lookup" check_rkn_ip_lookup
check_cmd_ok "parse release versions" check_parse_release_versions
check_cmd_ok "install summary render" check_install_summary_render
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
check_cmd_fail "invalid --meko-version value" bash "$ROOT/install.sh" --meko-version latest

[ "$FAIL" -eq 0 ] && echo "ALL SYNTAX OK" || exit 1
