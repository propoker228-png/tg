#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLUSTER_PANEL_SH_VERSION="1.0"
PANEL_METRICS_DIR="${PANEL_METRICS_DIR:-/var/lib/telemt-deploy/metrics}"

cluster_panel_node_status() {
  local metrics_file="$1" now_ts received_ts diff
  [ -f "$metrics_file" ] || { echo "offline"; return; }
  now_ts=$(date +%s)
  received_ts=$(python3 - <<'PY' "$metrics_file"
import json, sys
from datetime import datetime, timezone
try:
    data = json.load(open(sys.argv[1]))
    ts = data.get("received_at") or data.get("ts") or ""
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    if ts:
        print(int(datetime.fromisoformat(ts).timestamp()))
    else:
        print(0)
except Exception:
    print(0)
PY
)
  [ -n "$received_ts" ] && [ "$received_ts" -gt 0 ] || { echo "offline"; return; }
  diff=$((now_ts - received_ts))
  if [ "$diff" -lt 30 ]; then
    echo "online"
  elif [ "$diff" -lt 120 ]; then
    echo "stale"
  else
    echo "offline"
  fi
}

cluster_panel_read_metrics() {
  local node="$1" file="$PANEL_METRICS_DIR/${node}.json"
  python3 - <<'PY' "$file"
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
    print(int(data.get("people") or 0))
    print(int(data.get("tcp") or 0))
    print("true" if data.get("telemt_active") else "false")
except Exception:
    print(0)
    print(0)
    print("false")
PY
}

cluster_cli_status() {
  cluster_load
  local line name ip port people tcp telemt_active status total_people=0 total_tcp=0
  echo ""
  echo "Кластер: ${CLUSTER_DOMAIN:-не задан}"
  printf "  %-12s %-16s %-6s %-8s %-6s %-6s %-8s\n" "NODE" "IP" "PORT" "STATUS" "PEOPLE" "TCP" "TELEMT"
  cluster_init_nodes_file
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    read -r name ip port <<< "$line"
    port="${port:-443}"
    status=$(cluster_panel_node_status "$PANEL_METRICS_DIR/${name}.json")
    read -r people tcp telemt_active < <(cluster_panel_read_metrics "$name")
    total_people=$((total_people + people))
    total_tcp=$((total_tcp + tcp))
    printf "  %-12s %-16s %-6s %-8s %-6s %-6s %-8s\n" \
      "$name" "$ip" "$port" "$status" "$people" "$tcp" "$telemt_active"
  done < "$CLUSTER_NODES_FILE"
  echo ""
  echo "Итого: people=${total_people} tcp=${total_tcp}"
  local link
  link=$(cluster_get_proxy_link 2>/dev/null || true)
  [ -n "$link" ] && echo "Ссылка: $link"
  echo ""
}

cluster_cli_monitor() {
  cluster_load
  while true; do
    clear
    cluster_cli_status
    echo "Обновление каждые 4 с (q — выход)"
    if read -r -t 4 -n 1 key 2>/dev/null; then
      [ "$key" = "q" ] || [ "$key" = "Q" ] && break
    fi
  done
}

cluster_cli_panel_credentials() {
  if [ ! -f "${PANEL_CREDENTIALS_FILE:-/etc/telemt-deploy.panel}" ]; then
    die "Панель не установлена — выполните установку master_lb"
  fi
  panel_show_access_info
}

cluster_cli_migrate_domain() {
  local new_domain="${1:-}"
  [ -n "$new_domain" ] || die "Использование: tg cluster migrate-domain NEW_DOMAIN"
  cluster_migrate_domain "$new_domain"
}
