#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SPEEDTEST_SH_VERSION="1.2"
SPEEDTEST_PROFILE_QUICK="quick"
SPEEDTEST_PROFILE_FULL="full"

speedtest_format_mbit() {
  python3 - "$1" "$2" <<'PY'
import sys
bytes_, secs = float(sys.argv[1]), float(sys.argv[2])
if secs <= 0:
    print("0.0")
else:
    print(f"{(bytes_ * 8) / (secs * 1_000_000):.1f}")
PY
}

speedtest_profile_bytes() {
  case "${1:-quick}" in
    full|2) echo "104857600" ;;
    *) echo "10485760" ;;
  esac
}

speedtest_extract_json() {
  python3 <<'PY'
import json, sys
text = sys.stdin.read()
start = text.find("{")
end = text.rfind("}")
if start == -1 or end <= start:
    sys.exit(1)
try:
    data = json.loads(text[start : end + 1])
except json.JSONDecodeError:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
json.dump(data)
PY
}

speedtest_parse_json() {
  python3 <<'PY'
import json, sys

def to_mbit_from_bytes_per_sec(bytes_per_sec):
    return float(bytes_per_sec or 0) * 8 / 1_000_000

def to_mbit_from_bits_per_sec(bits_per_sec):
    return float(bits_per_sec or 0) / 1_000_000

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

dl_raw = data.get("download")
ul_raw = data.get("upload")
ping_raw = data.get("ping")

if isinstance(dl_raw, dict):
    dl = to_mbit_from_bytes_per_sec(dl_raw.get("bandwidth", 0))
    ul = to_mbit_from_bytes_per_sec(ul_raw.get("bandwidth", 0) if isinstance(ul_raw, dict) else 0)
    lat = ping_raw.get("latency", 0) if isinstance(ping_raw, dict) else 0
    jit = ping_raw.get("jitter", 0) if isinstance(ping_raw, dict) else 0
    srv = data.get("server", {})
    loc = srv.get("location") or srv.get("name") or srv.get("country") or "н/д"
    isp = data.get("isp") or "н/д"
else:
    dl = to_mbit_from_bits_per_sec(dl_raw)
    ul = to_mbit_from_bits_per_sec(ul_raw)
    lat = float(ping_raw or 0)
    jit = 0
    srv = data.get("server", {})
    loc = srv.get("name") or srv.get("country") or "н/д"
    client = data.get("client", {})
    isp = client.get("isp") or "н/д"

print(f"Download:  {dl:.1f} Mbit/s")
print(f"Upload:    {ul:.1f} Mbit/s")
print(f"Ping:      {lat:.1f} ms")
if jit:
    print(f"Jitter:    {jit:.1f} ms")
print(f"Server:    {loc}")
print(f"ISP:       {isp}")
PY
}

speedtest_cli_bin() {
  command -v speedtest 2>/dev/null || command -v speedtest-cli 2>/dev/null || true
}

speedtest_detect_backend() {
  local help version bin
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  version=$("$bin" --version 2>&1 || true)
  if printf '%s\n' "$version" | grep -qi 'ookla'; then
    echo "ookla"
    return 0
  fi
  help=$("$bin" --help 2>&1 || true)
  if printf '%s\n' "$help" | grep -qE '(^|[[:space:]])--format=json'; then
    echo "ookla"
    return 0
  fi
  if printf '%s\n' "$help" | grep -qE '(^|[[:space:]])--json'; then
    echo "legacy"
    return 0
  fi
  return 1
}

speedtest_install_ookla() {
  if speedtest_detect_backend >/dev/null 2>&1; then
    return 0
  fi
  if ! is_auto_mode; then
    confirm_action "Установить Ookla Speedtest CLI для полного теста (download/upload/ping)?" || return 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    apt-get install -y speedtest
  else
    log_warn "apt недоступен — Ookla не установлен"
    return 1
  fi
  speedtest_detect_backend >/dev/null 2>&1
}

speedtest_last_error_line() {
  local raw="$1" line
  line=$(printf '%s\n' "$raw" | grep -Evi '^\{' | grep -v '^[[:space:]]*$' | tail -1 || true)
  [ -n "$line" ] && log_warn "speedtest: ${line}"
}

speedtest_run_json_report() {
  local mode_label="$1" raw json
  raw="$2"
  [ -n "$raw" ] || return 1
  json=$(printf '%s\n' "$raw" | speedtest_extract_json) || return 1
  echo -e "${BOLD}Режим: ${mode_label}${NC}"
  printf '%s\n' "$json" | speedtest_parse_json || return 1
}

speedtest_run_cmd() {
  local bin="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

speedtest_run_ookla() {
  local raw bin
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  raw=$(speedtest_run_cmd "$bin" --accept-license --accept-gdpr --format=json 2>&1) || true
  speedtest_run_json_report "Ookla Speedtest" "$raw"
}

speedtest_run_legacy() {
  local raw bin
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  raw=$(speedtest_run_cmd "$bin" --json 2>&1) || true
  if speedtest_run_json_report "speedtest-cli" "$raw"; then
    return 0
  fi
  raw=$(speedtest_run_cmd "$bin" --json --secure 2>&1) || true
  if speedtest_run_json_report "speedtest-cli" "$raw"; then
    return 0
  fi
  speedtest_last_error_line "$raw"
  return 1
}

speedtest_run_full() {
  case "$(speedtest_detect_backend 2>/dev/null || true)" in
    ookla) speedtest_run_ookla ;;
    legacy) speedtest_run_legacy ;;
    *) return 1 ;;
  esac
}

speedtest_fallback_urls() {
  local profile="$1"
  case "$profile" in
    full|2)
      printf '%s\n' \
        'https://speed.cloudflare.com/__down?bytes=100000000' \
        'https://proof.ovh.net/files/100Mb.dat' \
        'https://speed.hetzner.de/100MB.bin'
      ;;
    *)
      printf '%s\n' \
        'https://speed.cloudflare.com/__down?bytes=10485760' \
        'https://proof.ovh.net/files/10Mb.dat'
      ;;
  esac
}

speedtest_run_fallback_download() {
  local profile="$1" url result time bytes mbit
  echo -e "${BOLD}Режим: упрощённый (curl/ping)${NC}"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    result=$(curl -4 -fsSL -o /dev/null -w '%{time_total} %{size_download}' --max-time 60 "$url" 2>/dev/null) || continue
    time="${result%% *}"
    bytes="${result##* }"
    mbit=$(speedtest_format_mbit "$bytes" "$time")
    echo "Download:  ${mbit} Mbit/s  (${url})"
    echo "Upload:    н/д (требуется speedtest-cli/Ookla)"
    return 0
  done < <(speedtest_fallback_urls "$profile")
  log_err "Не удалось скачать тестовый файл — проверьте сеть и firewall"
  return 1
}

speedtest_run_fallback_ping() {
  local host avg
  for host in 1.1.1.1 8.8.8.8; do
    if avg=$(ping -4 -c 4 -W 2 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5}'); then
      [ -n "$avg" ] && echo "Ping (${host}): ${avg} ms (avg)"
    fi
  done
}

run_speedtest() {
  local profile="${1:-quick}"
  log_warn "Тест использует интернет-трафик (полный режим может занять 1–2 мин)"
  if speedtest_detect_backend >/dev/null 2>&1 || speedtest_install_ookla; then
    speedtest_run_full && return 0
    log_warn "Speedtest не ответил — переключаюсь на упрощённый режим"
  fi
  speedtest_run_fallback_download "$profile" || return 1
  speedtest_run_fallback_ping
}

# Backward-compatible aliases for smoke tests
speedtest_extract_ookla_json() { speedtest_extract_json; }
speedtest_parse_ookla_json() { speedtest_parse_json; }
