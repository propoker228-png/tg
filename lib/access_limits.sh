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
