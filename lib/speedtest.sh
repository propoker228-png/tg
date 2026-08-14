#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SPEEDTEST_SH_VERSION="1.5"
SPEEDTEST_PROFILE_QUICK="quick"
SPEEDTEST_PROFILE_FULL="full"
SPEEDTEST_IP_FAMILY="${SPEEDTEST_IP_FAMILY:-}"

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

speedtest_profile_upload_mb() {
  case "${1:-quick}" in
    full|2) echo "25" ;;
    *) echo "10" ;;
  esac
}

speedtest_ip_family_label() {
  [ "${SPEEDTEST_IP_FAMILY:-4}" = "6" ] && echo "IPv6" || echo "IPv4"
}

speedtest_curl() {
  if [ "${SPEEDTEST_IP_FAMILY:-4}" = "6" ]; then
    curl -6 "$@"
  else
    curl -4 "$@"
  fi
}

speedtest_family_reachable() {
  local family="$1"
  case "$family" in
    6)
      curl -6 -fsSL --max-time 8 "https://www.speedtest.net/speedtest-config.php" >/dev/null 2>&1 \
        || curl -6 -fsSL --max-time 8 "https://speed.cloudflare.com/__down?bytes=1000" >/dev/null 2>&1
      ;;
    *)
      curl -4 -fsSL --max-time 8 "https://www.speedtest.net/speedtest-config.php" >/dev/null 2>&1 \
        || curl -4 -fsSL --max-time 8 "https://speed.cloudflare.com/__down?bytes=1000" >/dev/null 2>&1
      ;;
  esac
}

speedtest_detect_ip_family() {
  local v4=0 v6=0
  speedtest_family_reachable 4 && v4=1
  speedtest_family_reachable 6 && v6=1
  if [ "$v4" -eq 1 ]; then
    SPEEDTEST_IP_FAMILY=4
  elif [ "$v6" -eq 1 ]; then
    SPEEDTEST_IP_FAMILY=6
  elif getent ahostsv4 www.speedtest.net >/dev/null 2>&1; then
    SPEEDTEST_IP_FAMILY=4
  elif getent ahostsv6 www.speedtest.net >/dev/null 2>&1; then
    SPEEDTEST_IP_FAMILY=6
  else
    SPEEDTEST_IP_FAMILY=4
  fi
  export SPEEDTEST_IP_FAMILY
}

speedtest_primary_ip() {
  if [ "${SPEEDTEST_IP_FAMILY:-4}" = "6" ]; then
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}' | head -1
  else
    ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}' | head -1
  fi
}

speedtest_ping_targets() {
  if [ "${SPEEDTEST_IP_FAMILY:-4}" = "6" ]; then
    printf '%s\n' '2606:4700:4700::1111' '2001:4860:4860::8888'
  else
    printf '%s\n' '1.1.1.1' '8.8.8.8'
  fi
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

speedtest_config_reachable() {
  speedtest_curl -fsSL --max-time 10 "https://www.speedtest.net/speedtest-config.php" >/dev/null 2>&1
}

speedtest_dns_diagnose() {
  local v4=0 v6=0
  getent ahostsv4 www.speedtest.net >/dev/null 2>&1 && v4=1
  getent ahostsv6 www.speedtest.net >/dev/null 2>&1 && v6=1
  if [ "$v4" -eq 1 ] && [ "$v6" -eq 1 ]; then
    log_warn "speedtest.net: доступен по IPv4 и IPv6; тест по $(speedtest_ip_family_label)"
    return 0
  fi
  if [ "$v4" -eq 0 ] && [ "$v6" -eq 1 ]; then
    log_warn "speedtest.net: только IPv6 в DNS — используем IPv6"
    return 0
  fi
  if [ "$v4" -eq 1 ] && [ "$v6" -eq 0 ]; then
    log_warn "speedtest.net: только IPv4 в DNS — используем IPv4"
    return 0
  fi
  log_warn "speedtest.net не резолвится — проверьте /etc/resolv.conf"
  return 1
}

speedtest_mini_servers() {
  printf '%s\n' \
    'http://speedtest.tele2.net:8080/speedtest/upload.php' \
    'http://speedtest.belwue.net:8080/speedtest/upload.php'
}

speedtest_explain_failure() {
  local raw="$1"
  if printf '%s\n' "$raw" | grep -qi 'name resolution'; then
    speedtest_dns_diagnose || true
    if ! speedtest_config_reachable; then
      log_warn "speedtest-cli не может скачать speedtest-config.php по $(speedtest_ip_family_label)"
    fi
    return 0
  fi
  if printf '%s\n' "$raw" | grep -qi 'Cannot retrieve speedtest configuration'; then
    speedtest_dns_diagnose || true
    log_warn "speedtest-cli: не удалось получить список серверов ($(speedtest_ip_family_label))"
    return 0
  fi
  speedtest_last_error_line "$raw"
}

speedtest_run_json_report() {
  local mode_label="$1" raw json
  raw="$2"
  [ -n "$raw" ] || return 1
  json=$(printf '%s\n' "$raw" | speedtest_extract_json) || return 1
  echo -e "${BOLD}Режим: ${mode_label} ($(speedtest_ip_family_label))${NC}"
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

speedtest_ookla_ip_args() {
  local bin help
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 0
  help=$("$bin" --help 2>&1 || true)
  printf '%s\n' "$help" | grep -qE '(^|[[:space:]])--ip' || return 0
  if [ "${SPEEDTEST_IP_FAMILY:-4}" = "6" ]; then
    echo --ip=ipv6
  else
    echo --ip=ipv4
  fi
}

speedtest_legacy_bind_args() {
  local src
  src=$(speedtest_primary_ip)
  [ -n "$src" ] && echo --source "$src"
}

speedtest_run_ookla() {
  local raw bin ip_args
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  ip_args=$(speedtest_ookla_ip_args)
  # shellcheck disable=SC2086
  raw=$(speedtest_run_cmd "$bin" --accept-license --accept-gdpr $ip_args --format=json 2>&1) || true
  speedtest_run_json_report "Ookla Speedtest" "$raw"
}

speedtest_run_legacy() {
  local raw bin mini bind
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  bind=$(speedtest_legacy_bind_args)
  if ! speedtest_config_reachable; then
    speedtest_dns_diagnose || true
  fi
  # shellcheck disable=SC2086
  raw=$(speedtest_run_cmd "$bin" $bind --json 2>&1) || true
  if speedtest_run_json_report "speedtest-cli" "$raw"; then
    return 0
  fi
  # shellcheck disable=SC2086
  raw=$(speedtest_run_cmd "$bin" $bind --json --secure 2>&1) || true
  if speedtest_run_json_report "speedtest-cli" "$raw"; then
    return 0
  fi
  while IFS= read -r mini; do
    [ -n "$mini" ] || continue
    # shellcheck disable=SC2086
    raw=$(speedtest_run_cmd "$bin" $bind --json --mini "$mini" 2>&1) || true
    if speedtest_run_json_report "speedtest-cli (mini)" "$raw"; then
      return 0
    fi
  done < <(speedtest_mini_servers)
  speedtest_explain_failure "$raw"
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
  echo -e "${BOLD}Режим: упрощённый (curl/Cloudflare, $(speedtest_ip_family_label))${NC}"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    result=$(speedtest_curl -fsSL -o /dev/null -w '%{time_total} %{size_download}' --max-time 60 "$url" 2>/dev/null) || continue
    time="${result%% *}"
    bytes="${result##* }"
    mbit=$(speedtest_format_mbit "$bytes" "$time")
    echo "Download:  ${mbit} Mbit/s  (${url})"
    return 0
  done < <(speedtest_fallback_urls "$profile")
  log_err "Не удалось скачать тестовый файл — проверьте сеть и firewall"
  return 1
}

speedtest_run_fallback_upload() {
  local profile="$1" mb url time bytes mbit
  mb=$(speedtest_profile_upload_mb "$profile")
  bytes=$((mb * 1048576))
  url="https://speed.cloudflare.com/__up"
  time=$(dd if=/dev/zero bs=1M count="$mb" 2>/dev/null | speedtest_curl -fsSL -o /dev/null -w '%{time_total}' --max-time 120 -X POST -H "Content-Type: application/octet-stream" --data-binary @- "$url" 2>/dev/null) || {
    echo "Upload:    н/д (cloudflare недоступен по $(speedtest_ip_family_label))"
    return 1
  }
  mbit=$(speedtest_format_mbit "$bytes" "$time")
  echo "Upload:    ${mbit} Mbit/s  (${url}, ~${mb} MB)"
}

speedtest_run_fallback_ping() {
  local host avg
  while IFS= read -r host; do
    if avg=$(ping -"${SPEEDTEST_IP_FAMILY:-4}" -c 4 -W 2 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5}'); then
      [ -n "$avg" ] && echo "Ping (${host}): ${avg} ms (avg)"
    fi
  done < <(speedtest_ping_targets)
}

run_speedtest() {
  local profile="${1:-quick}"
  speedtest_detect_ip_family
  log_warn "Тест использует интернет-трафик ($(speedtest_ip_family_label), полный режим 1–2 мин)"
  if speedtest_detect_backend >/dev/null 2>&1 || speedtest_install_ookla; then
    speedtest_run_full && return 0
    log_warn "Переключаюсь на упрощённый режим (curl + Cloudflare upload, $(speedtest_ip_family_label))"
  fi
  speedtest_run_fallback_download "$profile" || return 1
  speedtest_run_fallback_upload "$profile" || true
  speedtest_run_fallback_ping
}

# Backward-compatible aliases for smoke tests
speedtest_last_error_line() {
  local raw="$1" line
  line=$(printf '%s\n' "$raw" | grep -Evi '^\{' | grep -v '^[[:space:]]*$' | tail -1 || true)
  [ -n "$line" ] && log_warn "speedtest: ${line}"
}
speedtest_extract_ookla_json() { speedtest_extract_json; }
speedtest_parse_ookla_json() { speedtest_parse_json; }
