#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ACCESS_LIMITS_SH_VERSION="1.0"
ACCESS_LIMITS_CONFIG_FILE="${ACCESS_LIMITS_CONFIG_FILE:-/etc/telemt/access-limits.json}"
ACCESS_LIMITS_TCP_MULTIPLIER=5
ACCESS_LIMITS_TCP_MIN=5
ACCESS_LIMITS_TOML_FILE="/etc/telemt/telemt.toml"
ACCESS_LIMITS_MARKER_BEGIN="# BEGIN telemt-deploy access limits"
ACCESS_LIMITS_MARKER_END="# END telemt-deploy access limits"

access_limits_derive_tcp_conns() {
  local devices="$1" tcp
  tcp=$((devices * ACCESS_LIMITS_TCP_MULTIPLIER))
  [ "$tcp" -ge "$ACCESS_LIMITS_TCP_MIN" ] || tcp="$ACCESS_LIMITS_TCP_MIN"
  echo "$tcp"
}

access_limits_validate_positive_int() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

access_limits_validate_tcp_conns() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge "$ACCESS_LIMITS_TCP_MIN" ]
}

access_limits_default_config() {
  printf '%s\n' '{"enabled":false,"max_devices":5,"max_unique_ips":5,"max_tcp_conns":25,"auto_tcp_from_devices":true}'
}

access_limits_load_config() {
  if [ ! -f "$ACCESS_LIMITS_CONFIG_FILE" ]; then
    ACCESS_LIMITS_ENABLED=0
    ACCESS_LIMITS_MAX_DEVICES=5
    ACCESS_LIMITS_MAX_UNIQUE_IPS=5
    ACCESS_LIMITS_MAX_TCP_CONNS=25
    ACCESS_LIMITS_AUTO_TCP=1
    export ACCESS_LIMITS_ENABLED ACCESS_LIMITS_MAX_DEVICES ACCESS_LIMITS_MAX_UNIQUE_IPS ACCESS_LIMITS_MAX_TCP_CONNS ACCESS_LIMITS_AUTO_TCP
    return 0
  fi
  eval "$(python3 - "$ACCESS_LIMITS_CONFIG_FILE" <<'PY'
import json, shlex, sys
data = json.load(open(sys.argv[1]))
print(f"ACCESS_LIMITS_ENABLED={1 if data.get('enabled') else 0}")
print(f"ACCESS_LIMITS_MAX_DEVICES={int(data.get('max_devices', 5))}")
print(f"ACCESS_LIMITS_MAX_UNIQUE_IPS={int(data.get('max_unique_ips', 5))}")
print(f"ACCESS_LIMITS_MAX_TCP_CONNS={int(data.get('max_tcp_conns', 25))}")
print(f"ACCESS_LIMITS_AUTO_TCP={1 if data.get('auto_tcp_from_devices', True) else 0}")
PY
)"
  export ACCESS_LIMITS_ENABLED ACCESS_LIMITS_MAX_DEVICES ACCESS_LIMITS_MAX_UNIQUE_IPS ACCESS_LIMITS_MAX_TCP_CONNS ACCESS_LIMITS_AUTO_TCP
}

access_limits_save_config() {
  local enabled="$1" max_devices="$2" max_unique_ips="$3" max_tcp_conns="$4" auto_tcp="$5"
  mkdir -p "$(dirname "$ACCESS_LIMITS_CONFIG_FILE")"
  python3 - "$ACCESS_LIMITS_CONFIG_FILE" "$enabled" "$max_devices" "$max_unique_ips" "$max_tcp_conns" "$auto_tcp" <<'PY'
import json, os, sys
path, enabled, max_devices, max_unique_ips, max_tcp_conns, auto_tcp = sys.argv[1:7]
data = {
    "enabled": enabled == "1",
    "max_devices": int(max_devices),
    "max_unique_ips": int(max_unique_ips),
    "max_tcp_conns": int(max_tcp_conns),
    "auto_tcp_from_devices": auto_tcp == "1",
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.chmod(path, 0o600)
PY
}

access_limits_ensure_config() {
  [ -f "$ACCESS_LIMITS_CONFIG_FILE" ] || access_limits_save_config 0 5 5 25 1
}

access_limits_strip_toml() {
  local path="$1"
  [ -f "$path" ] || return 0
  python3 - "$path" "$ACCESS_LIMITS_MARKER_BEGIN" "$ACCESS_LIMITS_MARKER_END" <<'PY'
import sys
path, begin, end = sys.argv[1:4]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    raise SystemExit(0)
out, skip = [], False
for line in lines:
    if line.strip() == begin:
        skip = True
        continue
    if line.strip() == end:
        skip = False
        continue
    if not skip:
        out.append(line)
text = "\n".join(out).rstrip() + "\n"
open(path, "w", encoding="utf-8").write(text)
PY
}

access_limits_render_fragment() {
  local unique_ips="$1" tcp_conns="$2" deploy_root="${DEPLOY_ROOT:-.}"
  export ACCESS_MAX_UNIQUE_IPS="$unique_ips" ACCESS_MAX_TCP_CONNS="$tcp_conns"
  envsubst '${ACCESS_MAX_UNIQUE_IPS} ${ACCESS_MAX_TCP_CONNS}' \
    < "$deploy_root/templates/telemt-access-limits.toml.tpl"
}

access_limits_merge_toml() {
  local path="$1" enabled="$2" unique_ips="$3" tcp_conns="$4" fragment
  access_limits_strip_toml "$path"
  [ "$enabled" = "1" ] || return 0
  fragment="$(access_limits_render_fragment "$unique_ips" "$tcp_conns")"
  {
    [ -s "$path" ] && cat "$path"
    printf '%s\n' "$ACCESS_LIMITS_MARKER_BEGIN"
    printf '%s\n' "$fragment"
    printf '%s\n' "$ACCESS_LIMITS_MARKER_END"
  } > "${path}.new"
  mv "${path}.new" "$path"
}

access_limits_format_status_line() {
  access_limits_load_config
  [ "${ACCESS_LIMITS_ENABLED:-0}" -eq 1 ] || { echo "лимит: выкл"; return 0; }
  local people="" conns=""
  if declare -f fetch_proxy_online_people >/dev/null 2>&1; then
    people=$(fetch_proxy_online_people)
  else
    people="?"
  fi
  if declare -f fetch_proxy_connections_total >/dev/null 2>&1; then
    conns=$(fetch_proxy_connections_total)
  else
    conns="?"
  fi
  echo "лимит: ${people}/${ACCESS_LIMITS_MAX_DEVICES} устройств (IP: ${people}/${ACCESS_LIMITS_MAX_UNIQUE_IPS}, TCP: ${conns}/${ACCESS_LIMITS_MAX_TCP_CONNS})"
}

access_limits_apply() {
  access_limits_load_config
  [ -f "$ACCESS_LIMITS_TOML_FILE" ] || die "telemt.toml не найден: $ACCESS_LIMITS_TOML_FILE"
  access_limits_merge_toml "$ACCESS_LIMITS_TOML_FILE" \
    "$ACCESS_LIMITS_ENABLED" "$ACCESS_LIMITS_MAX_UNIQUE_IPS" "$ACCESS_LIMITS_MAX_TCP_CONNS"
  if systemctl is-active --quiet telemt 2>/dev/null; then
    systemctl restart telemt || die "telemt не перезапустился после применения лимитов"
    systemctl is-active --quiet telemt || {
      journalctl -u telemt --no-pager -n 20
      die "telemt не active после применения лимитов"
    }
  fi
}
