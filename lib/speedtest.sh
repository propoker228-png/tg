#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SPEEDTEST_SH_VERSION="1.0"
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

speedtest_parse_ookla_json() {
  python3 - "$1" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
dl = data.get("download", {}).get("bandwidth", 0) * 8 / 1_000_000
ul = data.get("upload", {}).get("bandwidth", 0) * 8 / 1_000_000
ping = data.get("ping", {})
lat = ping.get("latency", 0)
jit = ping.get("jitter", 0)
srv = data.get("server", {})
loc = srv.get("location") or srv.get("name") or "н/д"
isp = data.get("isp") or "н/д"
print(f"Download:  {dl:.1f} Mbit/s")
print(f"Upload:    {ul:.1f} Mbit/s")
print(f"Ping:      {lat:.1f} ms")
print(f"Jitter:    {jit:.1f} ms")
print(f"Server:    {loc}")
print(f"ISP:       {isp}")
PY
}

speedtest_has_ookla() {
  command -v speedtest >/dev/null 2>&1 && speedtest --version >/dev/null 2>&1
}

speedtest_install_ookla() {
  if speedtest_has_ookla; then
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
  speedtest_has_ookla
}

speedtest_run_ookla() {
  local json
  json=$(speedtest --accept-license --accept-gdpr --format=json 2>/dev/null) || return 1
  echo -e "${BOLD}Режим: Ookla Speedtest${NC}"
  speedtest_parse_ookla_json "$json"
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
    echo "Upload:    н/д (требуется Ookla)"
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
  log_warn "Тест использует интернет-трафик"
  if speedtest_has_ookla || speedtest_install_ookla; then
    speedtest_run_ookla && return 0
    log_warn "Ookla не ответил — переключаюсь на упрощённый режим"
  fi
  speedtest_run_fallback_download "$profile" || return 1
  speedtest_run_fallback_ping
}
