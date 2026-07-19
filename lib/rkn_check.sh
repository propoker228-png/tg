#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"

RKN_CHECK_SH_VERSION="1.0"
RKN_CACHE_DIR="/var/cache/telemt-deploy"
RKN_CACHE_FILE="${RKN_CACHE_DIR}/rkn-ips.json"
RKN_CACHE_TTL=21600
RKN_IPS_URLS=(
  "https://api.reserve-rbl.ru/api/v3/ips-only/json"
  "https://reestr.rublacklist.net/api/v3/ips/"
)
RKN_EXPORT_URL="https://reestr.rublacklist.net/export/"

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS=. read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

rkn_cache_is_fresh() {
  [ -f "$RKN_CACHE_FILE" ] || return 1
  local age now mtime
  now=$(date +%s)
  mtime=$(stat -c %Y "$RKN_CACHE_FILE" 2>/dev/null || echo 0)
  age=$((now - mtime))
  [ "$age" -lt "$RKN_CACHE_TTL" ]
}

rkn_download_ips_cache() {
  local url tmp ok=1
  mkdir -p "$RKN_CACHE_DIR"
  tmp=$(mktemp)
  for url in "${RKN_IPS_URLS[@]}"; do
    if curl -fsSL --max-time 60 -H "User-Agent: telemt-deploy" "$url" -o "$tmp" 2>/dev/null; then
      if python3 - "$tmp" "$RKN_CACHE_FILE" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read().decode("utf-8", "replace").strip()
entries = []
if not raw:
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)
if isinstance(data, list):
    for item in data:
        if isinstance(item, str):
            entries.append(item.strip())
        elif isinstance(item, dict):
            for key in ("ip", "addr", "address", "subnet"):
                if key in item and item[key]:
                    entries.append(str(item[key]).strip())
elif isinstance(data, dict):
    for key in ("ips", "data", "result"):
        if key in data and isinstance(data[key], list):
            for item in data[key]:
                if isinstance(item, str):
                    entries.append(item.strip())
entries = [e for e in entries if e]
if not entries:
    sys.exit(1)
json.dump(sorted(set(entries)), open(dst, "w"))
PY
      then
        ok=0
        break
      fi
    fi
  done
  rm -f "$tmp"
  [ "$ok" -eq 0 ]
}

rkn_ensure_ips_cache() {
  if rkn_cache_is_fresh; then
    return 0
  fi
  log_info "Загрузка реестра IP РКН (кэш ${RKN_CACHE_TTL}s)..."
  rkn_download_ips_cache
}

rkn_lookup_ip_in_cache() {
  local ip="$1" cache="${2:-$RKN_CACHE_FILE}"
  python3 - "$ip" "$cache" <<'PY'
import ipaddress, json, sys
ip, cache = sys.argv[1], sys.argv[2]
target = ipaddress.ip_address(ip)
data = json.load(open(cache))
for entry in data:
    entry = str(entry).strip()
    if not entry:
        continue
    try:
        if "/" in entry:
            if target in ipaddress.ip_network(entry, strict=False):
                print("BLOCKED")
                raise SystemExit(0)
        elif target == ipaddress.ip_address(entry):
            print("BLOCKED")
            raise SystemExit(0)
    except ValueError:
        continue
print("FREE")
PY
}

rkn_lookup_ip_export() {
  local ip="$1" body
  body=$(curl -fsSL --max-time 20 -H "User-Agent: telemt-deploy" \
    "${RKN_EXPORT_URL}?q=${ip}&export=records" 2>/dev/null) || return 1
  [ -n "$body" ] || return 1
  if echo "$body" | grep -qiE "${ip}|заблок|blocked"; then
    echo "BLOCKED"
    return 0
  fi
  if echo "$body" | grep -qi "не найден\|not found\|0 records"; then
    echo "FREE"
    return 0
  fi
  return 1
}

check_rkn_ip() {
  local ip="${1:-$(get_public_ip)}"
  local status source="cache"

  is_valid_ipv4 "$ip" || die "Некорректный IPv4: $ip"

  echo ""
  echo -e "${BOLD}=== Проверка IP в реестре РКН ===${NC}"
  echo -e "  IP: $(hl_domain "$ip")"

  if rkn_ensure_ips_cache; then
    status=$(rkn_lookup_ip_in_cache "$ip" 2>/dev/null || echo "UNKNOWN")
  else
    log_warn "Не удалось загрузить список IP — пробуем поиск export (лимит ~50/сутки)"
    status=$(rkn_lookup_ip_export "$ip" 2>/dev/null || echo "UNKNOWN")
    source="export"
  fi

  case "$status" in
    FREE)
      log_ok "IP не найден в реестре заблокированных (${source})"
      echo -e "  ${GRAY}Ручная проверка: https://blocklist.rkn.gov.ru/${NC}"
      return 0
      ;;
    BLOCKED)
      log_err "IP найден в реестре РКН (${source})"
      echo -e "  ${YELLOW}Рекомендация: смените IP сервера или хостинг${NC}"
      echo -e "  ${GRAY}Ручная проверка: https://blocklist.rkn.gov.ru/${NC}"
      return 1
      ;;
    *)
      log_warn "Не удалось проверить IP в реестре РКН"
      echo -e "  ${GRAY}Проверьте вручную: https://reestr.rublacklist.net/${NC}"
      echo -e "  ${GRAY}Официально: https://blocklist.rkn.gov.ru/${NC}"
      return 2
      ;;
  esac
}
