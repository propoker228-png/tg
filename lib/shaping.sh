#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SHAPING_SH_VERSION="1.0"
SHAPING_CONFIG_FILE="${SHAPING_CONFIG_FILE:-/etc/telemt/shaping.json}"
SHAPING_APPLY_SCRIPT="/usr/local/bin/telemt-shaping-apply.sh"
SHAPING_CLASS_BASE=10
SHAPING_TC_UNLIMITED_RATE="1000mbit"

shaping_mbit_to_tc_rate() {
  local mbit="$1"
  printf '%smbit' "$mbit"
}

shaping_validate_mbit() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v v="$v" 'BEGIN { exit !(v >= 0 && v <= 10000) }'
}

shaping_effective_limit() {
  local ip="$1" enabled="$2" global_mbit="$3" overrides_json="$4"
  if [ "$enabled" != "1" ]; then
    echo "unlimited"
    return 0
  fi
  python3 - "$ip" "$global_mbit" "$overrides_json" <<'PY'
import json, sys

ip, global_mbit, overrides_json = sys.argv[1], float(sys.argv[2]), sys.argv[3]
overrides = json.loads(overrides_json or "{}")

def fmt_num(n):
    return str(int(n)) if float(n) == int(float(n)) else str(n)

if ip in overrides:
    val = overrides[ip]
    if val is None:
        print("unlimited")
    else:
        print(fmt_num(val))
    raise SystemExit(0)

if global_mbit > 0:
    print(fmt_num(global_mbit))
else:
    print("unlimited")
PY
}

shaping_default_config() {
  printf '%s\n' '{"enabled":false,"global_mbit":0,"overrides":{}}'
}

shaping_load_config() {
  if [ ! -f "$SHAPING_CONFIG_FILE" ]; then
    SHAPING_ENABLED=0
    SHAPING_GLOBAL_MBIT=0
    SHAPING_OVERRIDES_JSON='{}'
    export SHAPING_ENABLED SHAPING_GLOBAL_MBIT SHAPING_OVERRIDES_JSON
    return 0
  fi
  eval "$(python3 - "$SHAPING_CONFIG_FILE" <<'PY'
import json, shlex, sys

data = json.load(open(sys.argv[1]))
print(f"SHAPING_ENABLED={1 if data.get('enabled') else 0}")
g = data.get("global_mbit", 0)
if isinstance(g, float) and g == int(g):
    g = int(g)
print(f"SHAPING_GLOBAL_MBIT={g}")
print("SHAPING_OVERRIDES_JSON=" + shlex.quote(json.dumps(data.get("overrides") or {})))
PY
)"
  export SHAPING_ENABLED SHAPING_GLOBAL_MBIT SHAPING_OVERRIDES_JSON
}

shaping_save_config() {
  local enabled="$1" global_mbit="$2" overrides_json="$3"
  mkdir -p "$(dirname "$SHAPING_CONFIG_FILE")"
  python3 - "$SHAPING_CONFIG_FILE" "$enabled" "$global_mbit" "$overrides_json" <<'PY'
import json, os, sys

path, enabled, global_mbit, overrides_json = sys.argv[1:5]
data = {
    "enabled": enabled == "1",
    "global_mbit": float(global_mbit),
    "overrides": json.loads(overrides_json or "{}"),
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.chmod(path, 0o600)
PY
}

shaping_ensure_config() {
  [ -f "$SHAPING_CONFIG_FILE" ] || shaping_save_config 0 0 '{}'
}

shaping_override_set_mbit() {
  local ip="$1" mbit="$2"
  shaping_load_config
  SHAPING_OVERRIDES_JSON=$(python3 - "$ip" "$mbit" "$SHAPING_OVERRIDES_JSON" <<'PY'
import json, sys
ip, mbit, raw = sys.argv[1], float(sys.argv[2]), sys.argv[3]
overrides = json.loads(raw or "{}")
overrides[ip] = int(mbit) if mbit == int(mbit) else mbit
print(json.dumps(overrides))
PY
)
  shaping_save_config "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON"
}

shaping_override_set_unlimited() {
  local ip="$1"
  shaping_load_config
  SHAPING_OVERRIDES_JSON=$(python3 - "$ip" "$SHAPING_OVERRIDES_JSON" <<'PY'
import json, sys
ip, raw = sys.argv[1], sys.argv[2]
overrides = json.loads(raw or "{}")
overrides[ip] = None
print(json.dumps(overrides))
PY
)
  shaping_save_config "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON"
}

shaping_override_remove() {
  local ip="$1"
  shaping_load_config
  SHAPING_OVERRIDES_JSON=$(python3 - "$ip" "$SHAPING_OVERRIDES_JSON" <<'PY'
import json, sys
ip, raw = sys.argv[1], sys.argv[2]
overrides = json.loads(raw or "{}")
overrides.pop(ip, None)
print(json.dumps(overrides))
PY
)
  shaping_save_config "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON"
}

shaping_has_override() {
  local ip="$1"
  shaping_load_config
  python3 - "$ip" "$SHAPING_OVERRIDES_JSON" <<'PY'
import json, sys
ip, raw = sys.argv[1], sys.argv[2]
overrides = json.loads(raw or "{}")
raise SystemExit(0 if ip in overrides else 1)
PY
}

shaping_format_ip_limit() {
  local ip="$1" limit label
  shaping_load_config
  limit=$(shaping_effective_limit "$ip" "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON")
  label=$(python3 - "$ip" "$SHAPING_OVERRIDES_JSON" <<'PY'
import json, sys
ip, raw = sys.argv[1], sys.argv[2]
overrides = json.loads(raw or "{}")
if ip not in overrides:
    print("глобальный")
elif overrides[ip] is None:
    print("override, без лимита")
else:
    print("индивидуальный")
PY
)
  if [ "$limit" = "unlimited" ]; then
    echo "без лимита ($label)"
  else
    echo "${limit} Mbit/s ($label)"
  fi
}

shaping_restore_fq() {
  local iface="$1"
  [ -n "$iface" ] || return 0
  tc qdisc replace dev "$iface" root fq 2>/dev/null || true
}

shaping_collect_active_ips() {
  if declare -f fetch_active_ips_list >/dev/null 2>&1; then
    fetch_active_ips_list
  fi
}

shaping_apply() {
  local iface limit ip classid=0 mbit count=0
  declare -A seen=()

  iface="$(monitor_default_iface)"
  [ -n "$iface" ] || { log_err "Интерфейс не найден"; return 1; }
  command -v tc >/dev/null 2>&1 || { log_err "tc не найден (пакет iproute2)"; return 1; }

  shaping_load_config
  if [ "${SHAPING_ENABLED:-0}" -ne 1 ]; then
    shaping_restore_fq "$iface"
    return 0
  fi

  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 999
  tc class add dev "$iface" parent 1: classid 1:1 htb rate "$SHAPING_TC_UNLIMITED_RATE" ceil "$SHAPING_TC_UNLIMITED_RATE"
  tc class add dev "$iface" parent 1:1 classid 1:999 htb rate "$SHAPING_TC_UNLIMITED_RATE" ceil "$SHAPING_TC_UNLIMITED_RATE"

  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    [ -n "${seen[$ip]+x}" ] && continue
    seen[$ip]=1
    count=$((count + 1))
    limit=$(shaping_effective_limit "$ip" "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON")
    [ "$limit" = "unlimited" ] && continue
    classid=$((SHAPING_CLASS_BASE + count))
    if [ "$classid" -gt 4095 ]; then
      log_warn "Слишком много IP для tc (>${SHAPING_CLASS_BASE})"
      break
    fi
    mbit=$(shaping_mbit_to_tc_rate "$limit")
    tc class add dev "$iface" parent 1:1 classid "1:${classid}" htb rate "$mbit" ceil "$mbit"
    tc filter add dev "$iface" protocol ip parent 1:0 prio 1 u32 \
      match ip dst "$ip/32" flowid "1:${classid}"
  done < <(shaping_collect_active_ips | sort -u)

  [ "$count" -gt 500 ] && log_warn "Активных IP: ${count} — большая нагрузка на tc"
  return 0
}

shaping_install_units() {
  local deploy_root="${DEPLOY_ROOT:-/root/telemt-deploy}"
  [ -f "$deploy_root/templates/telemt-shaping-apply.sh" ] || die "templates/telemt-shaping-apply.sh не найден"
  install -m 755 "$deploy_root/templates/telemt-shaping-apply.sh" "$SHAPING_APPLY_SCRIPT"
  cp "$deploy_root/templates/telemt-shaping.service" /etc/systemd/system/telemt-shaping.service
  cp "$deploy_root/templates/telemt-shaping.timer" /etc/systemd/system/telemt-shaping.timer
  systemctl daemon-reload
  systemctl enable telemt-shaping.timer
  systemctl restart telemt-shaping.timer
  log_ok "telemt-shaping timer установлен"
}

shaping_ensure_units() {
  [ -f /etc/systemd/system/telemt-shaping.timer ] || shaping_install_units
}

shaping_pick_ip() {
  local choice="" ip="" n=0
  local -a ips=()

  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip")
  done < <(shaping_collect_active_ips | sort -u)

  if [ "${#ips[@]}" -eq 0 ]; then
    prompt_line ip "IPv4 клиента" ""
    is_valid_ipv4 "$ip" || { log_warn "Некорректный IPv4"; return 1; }
    printf '%s' "$ip"
    return 0
  fi

  echo ""
  echo "  Активные IP:"
  for ip in "${ips[@]}"; do
    n=$((n + 1))
    printf '    %2d) %s — %s\n' "$n" "$ip" "$(shaping_format_ip_limit "$ip")"
  done
  echo "    m) Ввести IP вручную"
  prompt_line choice "Выбор IP" ""
  if [ "$choice" = "m" ] || [ "$choice" = "M" ]; then
    prompt_line ip "IPv4 клиента" ""
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ips[@]}" ]; then
    ip="${ips[$((choice - 1))]}"
  else
    log_warn "Неверный выбор"
    return 1
  fi
  is_valid_ipv4 "$ip" || { log_warn "Некорректный IPv4"; return 1; }
  printf '%s' "$ip"
}

shaping_set_global_limit() {
  local mbit="$1"
  shaping_validate_mbit "$mbit" || return 1
  shaping_load_config
  if awk -v v="$mbit" 'BEGIN { exit !(v > 0) }'; then
    shaping_save_config 1 "$mbit" "$SHAPING_OVERRIDES_JSON"
  else
    shaping_save_config 0 0 "$SHAPING_OVERRIDES_JSON"
  fi
}

shaping_disable_all() {
  shaping_load_config
  shaping_save_config 0 "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON"
}
