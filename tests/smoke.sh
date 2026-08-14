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
    STUB_SITE="global-cdn"
    TELEMT_VERSION="3.4.24"
    MEKO_VERSION="3.0.1"
    MEKO_FULL=0
    SYN_FIX_MODE="meko"
    TELEMT_VERSION_HINT="★ latest"
    out=$(print_install_summary)
    [[ "$out" == *"example.com"* ]]
    [[ "$out" == *"3.4.24"* ]]
    [[ "$out" == *"3.0.1"* ]]
    [[ "$out" == *"Global CDN"* ]]
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

check_monitor_network_helpers() {
  (
    # shellcheck source=../lib/monitor.sh
    source "$ROOT/lib/monitor.sh"
    [ "$(monitor_format_bitrate 59800000)" = "59.8 Mbit/s" ]
    [ "$(monitor_format_bytes_short 1048576)" = "1.0 MiB" ]
    [ "$(monitor_format_mib 1048576)" = "1.00 GiB" ]
    [ "$(monitor_format_percent 45.25)" = "45.3%" ]
    [ -n "$(monitor_default_iface)" ]
    [ -n "$(monitor_read_mem_kib MemTotal)" ]
    read -r _total _idle < <(monitor_read_cpu_totals)
    [ -n "${_total:-}" ] && [ -n "${_idle:-}" ]
  )
}

check_mask_picker_helpers() {
  (
    # shellcheck source=../lib/mask_picker.sh
    source "$ROOT/lib/mask_picker.sh"
    DOMAIN="proxy.example.com"
    TLS_DOMAIN="mask.example.org"
    [ "$(telemt_mask_domain)" = "mask.example.org" ]
    TLS_DOMAIN=""
    [ "$(telemt_mask_domain)" = "proxy.example.com" ]
    cidr=$(mask_detect_scan_cidr "90.156.254.235")
    [ "$cidr" = "90.156.254.0/24" ]
    INSTALL_IP_ONLY=1
    DOMAIN="90.156.254.235"
    is_valid_ipv4 "$DOMAIN"
    ! is_valid_ipv4 "mask.example.org"
  )
}

check_prereq_cmd_mapping() {
  (
    # shellcheck source=../lib/prereq.sh
    source "$ROOT/lib/prereq.sh"
    [ "$(_prereq_pkg_for_cmd dig)" = "dnsutils" ]
    [ "$(_prereq_pkg_for_cmd envsubst)" = "gettext-base" ]
    [ "$(_prereq_pkg_for_cmd ss)" = "iproute2" ]
    [ "$(_prereq_pkg_for_cmd tc)" = "iproute2" ]
  )
}

check_stub_site_template() {
  local id
  for id in it-services managed-ftp global-cdn marketplace image-hosting auto-parts cloud-storage saas-analytics logistics; do
    [ -f "$ROOT/templates/sites/$id/index.html" ] \
      && [ -f "$ROOT/templates/sites/$id/contact.html" ] \
      && [ -f "$ROOT/templates/sites/$id/assets/style.css" ] || return 1
  done
}

check_stub_site_resolver() {
  (
    # shellcheck source=../lib/stub_site.sh
    source "$ROOT/lib/stub_site.sh"
    [ "$(stub_site_resolve 3)" = "global-cdn" ]
    [ "$(stub_site_resolve marketplace)" = "marketplace" ]
    [ "$(stub_site_resolve auto-parts)" = "auto-parts" ]
    ! stub_site_resolve unknown-theme
  )
}

check_install_step_runner() {
  (
    # shellcheck source=../lib/install_step.sh
    source "$ROOT/lib/install_step.sh"
    _fail_step() { return 42; }
    _ok_step() { return 0; }
    install_step_run_once _ok_step
    ! install_step_run_once _fail_step
    INSTALL_SKIPPED_STEPS=("ssl")
    install_step_skipped ssl
    ! install_step_skipped telemt
  )
}

check_syn_fix_resolver() {
  (
    # shellcheck source=../lib/syn_fix.sh
    source "$ROOT/lib/syn_fix.sh"
    [ "$(syn_fix_resolve 1)" = "meko" ]
    [ "$(syn_fix_resolve zapret2)" = "zapret2" ]
    [ "$(syn_fix_resolve none)" = "none" ]
    ! syn_fix_resolve unknown-mode
  )
}

check_zapret2_templates() {
  [ -f "$ROOT/templates/zapret2/mtproto.lua" ] \
    && [ -f "$ROOT/templates/zapret2/tg-zapret2.service" ] \
    && [ -f "$ROOT/templates/zapret2/tg-zapret2-start.sh.tpl" ]
}

check_zapret2_render() {
  (
    DEPLOY_ROOT="$ROOT"
    ZAPRET2_DIR="/opt/tg-zapret2"
    ZAPRET2_ETC_DIR="/etc/tg-zapret2"
    ZAPRET2_NFT_TABLE="TgDeployZ2"
    ZAPRET2_QNUM=200
    PROXY_PORT=443
    export DEPLOY_ROOT ZAPRET2_DIR ZAPRET2_ETC_DIR ZAPRET2_NFT_TABLE ZAPRET2_QNUM PROXY_PORT
    tmp="$(mktemp)"
    envsubst '${ZAPRET2_NFT_TABLE} ${ZAPRET2_DIR} ${ZAPRET2_ETC_DIR} ${ZAPRET2_QNUM} ${PROXY_PORT}' \
      < "$ROOT/templates/zapret2/tg-zapret2-start.sh.tpl" > "$tmp"
    grep -q 'TABLE="TgDeployZ2"' "$tmp"
    ! grep -q 'ZAPRET2_NFT_TABLE' "$tmp"
    rm -f "$tmp"
  )
}

check_install_ip_only_from_domain() {
  (
    # shellcheck source=../lib/common.sh
    source "$ROOT/lib/common.sh"
    DOMAIN="31.76.240.187"
    INSTALL_IP_ONLY=0
    install_is_ip_only
    install_sync_ip_only_from_domain
    [ "${INSTALL_IP_ONLY:-0}" -eq 1 ]
  )
}

check_require_valid_domain_rejects_ip() {
  (
    # shellcheck source=../lib/common.sh
    source "$ROOT/lib/common.sh"
    require_valid_domain_name "31.76.240.187"
  ) && return 1
  return 0
}

check_handoff_no_secret() {
  (
    # shellcheck source=../lib/env.sh
    source "$ROOT/lib/env.sh"
    # shellcheck source=../lib/handoff.sh
    source "$ROOT/lib/handoff.sh"
    unset SECRET
    show_mtproxybot_handoff "203.0.113.10" | grep -q "н/д"
  )
}

check_handoff_loads_secret_file() {
  (
    local tmp="$ROOT/.tmp-handoff-secret"
    # shellcheck source=../lib/env.sh
    source "$ROOT/lib/env.sh"
    # shellcheck source=../lib/handoff.sh
    source "$ROOT/lib/handoff.sh"
    printf '%s' '0123456789abcdef0123456789abcdef' > "$tmp"
    SECRET_FILE="$tmp"
    export SECRET_FILE
    unset SECRET
    env_load_secret
    [ "${SECRET:-}" = "0123456789abcdef0123456789abcdef" ]
    rm -f "$tmp"
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
check_cmd_ok "install ip-only from domain" check_install_ip_only_from_domain
check_cmd_ok "require_valid_domain rejects ip" check_require_valid_domain_rejects_ip
check_cmd_ok "handoff without secret" check_handoff_no_secret
check_cmd_ok "handoff loads secret file" check_handoff_loads_secret_file
check_cmd_ok "parse release versions" check_parse_release_versions
check_cmd_ok "install summary render" check_install_summary_render
check_cmd_ok "common helper validators" check_helpers
check_cmd_ok "meko version helpers" check_meko_version_helpers
check_cmd_ok "monitor network helpers" check_monitor_network_helpers
check_cmd_ok "mask picker helpers" check_mask_picker_helpers
check_cmd_ok "prereq command mapping" check_prereq_cmd_mapping
check_cmd_ok "stub site templates present" check_stub_site_template
check_cmd_ok "stub site resolver" check_stub_site_resolver
check_cmd_ok "syn fix resolver" check_syn_fix_resolver
check_cmd_ok "install step runner" check_install_step_runner
check_cmd_ok "zapret2 templates present" check_zapret2_templates
check_cmd_ok "zapret2 start script render" check_zapret2_render
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
check_cmd_fail "invalid --syn-fix value" bash "$ROOT/install.sh" --syn-fix bogus

bash "$ROOT/tests/proxy_mode_smoke.sh" || FAIL=1
bash "$ROOT/tests/meko_diag_smoke.sh" || FAIL=1
bash "$ROOT/tests/shaping_smoke.sh" || FAIL=1

[ "$FAIL" -eq 0 ] && echo "ALL SYNTAX OK" || exit 1
