#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SPEEDTEST_SH_VERSION="1.18"
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
  # python3 -c (not heredoc): heredoc steals stdin and breaks piped input
  python3 -c 'import json, sys

def is_valid_result(data):
    if not isinstance(data, dict):
        return False
    if data.get("type") == "log":
        return False
    dl = data.get("download")
    ul = data.get("upload")
    if isinstance(dl, dict):
        return (dl.get("bandwidth") or 0) > 0 or (
            isinstance(ul, dict) and (ul.get("bandwidth") or 0) > 0
        )
    if isinstance(dl, (int, float)):
        return dl > 0 or (isinstance(ul, (int, float)) and ul > 0)
    return False

text = sys.stdin.read()
for line in text.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        continue
    if is_valid_result(data):
        json.dump(data, sys.stdout)
        sys.exit(0)
start = text.find("{")
end = text.rfind("}")
if start == -1 or end <= start:
    sys.exit(1)
try:
    data = json.loads(text[start : end + 1])
except json.JSONDecodeError:
    sys.exit(1)
if not is_valid_result(data):
    sys.exit(1)
json.dump(data, sys.stdout)'
}

speedtest_ookla_raw_has_result() {
  printf '%s\n' "$1" | speedtest_extract_json >/dev/null 2>&1
}

speedtest_parse_json() {
  python3 -c 'import json, sys

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

if dl <= 0 and ul <= 0:
    sys.exit(1)

print(f"Download:  {dl:.1f} Mbit/s")
print(f"Upload:    {ul:.1f} Mbit/s")
print(f"Ping:      {lat:.1f} ms")
if jit:
    print(f"Jitter:    {jit:.1f} ms")
print(f"Server:    {loc}")
print(f"ISP:       {isp}")'
}

speedtest_is_ookla_bin() {
  local bin="$1" version help
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  version=$("$bin" --version 2>&1 || true)
  if printf '%s\n' "$version" | grep -qi 'ookla'; then
    return 0
  fi
  help=$("$bin" --help 2>&1 || true)
  printf '%s\n' "$help" | grep -qE '(^|[[:space:]])--format=json'
}

speedtest_is_ookla_installed() {
  local bin
  for bin in /usr/bin/speedtest /usr/local/bin/speedtest; do
    speedtest_is_ookla_bin "$bin" && return 0
  done
  bin=$(command -v speedtest 2>/dev/null || true)
  speedtest_is_ookla_bin "$bin"
}

speedtest_is_legacy_installed() {
  local bin help
  speedtest_is_ookla_installed && return 1
  for bin in /usr/bin/speedtest /usr/bin/speedtest-cli /usr/local/bin/speedtest /usr/local/bin/speedtest-cli; do
    [ -x "$bin" ] || continue
    help=$("$bin" --help 2>&1 || true)
    if printf '%s\n' "$help" | grep -qE '(^|[[:space:]])--json'; then
      return 0
    fi
  done
  return 1
}

speedtest_cli_bin() {
  local bin
  for bin in /usr/bin/speedtest /usr/local/bin/speedtest; do
    speedtest_is_ookla_bin "$bin" && echo "$bin" && return 0
  done
  command -v speedtest 2>/dev/null || command -v speedtest-cli 2>/dev/null || true
}

speedtest_detect_backend() {
  if speedtest_is_ookla_installed; then
    echo "ookla"
    return 0
  fi
  if speedtest_is_legacy_installed; then
    echo "legacy"
    return 0
  fi
  return 1
}

speedtest_apt_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

speedtest_remove_legacy() {
  local pkg removed=0
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    for pkg in speedtest-cli python3-speedtest-cli; do
      if speedtest_apt_pkg_installed "$pkg"; then
        log_warn "Удаляю пакет $pkg"
        apt-get purge -y "$pkg" >/dev/null 2>&1 || apt-get remove -y "$pkg" >/dev/null 2>&1 || true
        removed=1
      fi
    done
    if speedtest_apt_pkg_installed speedtest && ! speedtest_is_ookla_installed; then
      local help
      help=$(speedtest --help 2>&1 || true)
      if printf '%s\n' "$help" | grep -qE '(^|[[:space:]])--json'; then
        log_warn "Удаляю пакет speedtest (устаревший speedtest-cli)"
        apt-get purge -y speedtest >/dev/null 2>&1 || apt-get remove -y speedtest >/dev/null 2>&1 || true
        removed=1
      fi
    fi
  fi
  if command -v pip3 >/dev/null 2>&1; then
    pip3 uninstall -y speedtest-cli speedtest 2>/dev/null && removed=1 || true
  fi
  rm -f /usr/local/bin/speedtest-cli 2>/dev/null || true
  hash -r 2>/dev/null || true
  [ "$removed" -eq 1 ] && log_ok "Старый speedtest-cli удалён"
}

speedtest_fixup_ookla_apt_repo() {
  local f codename fixed=0
  codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
  for f in /etc/apt/sources.list.d/ookla_speedtest-cli.list /etc/apt/sources.list.d/ookla-speedtest-cli.list; do
    [ -f "$f" ] || continue
    if grep -qE '/ubuntu (noble|'"${codename}"') ' "$f" 2>/dev/null; then
      sed -i 's/ubuntu noble/ubuntu jammy/g' "$f"
      [ -n "$codename" ] && [ "$codename" != "noble" ] && sed -i "s/ubuntu ${codename}/ubuntu jammy/g" "$f" 2>/dev/null || true
      fixed=1
    fi
  done
  [ "$fixed" -eq 1 ] && log_warn "Ookla repo: ${codename:-noble} → jammy (workaround Ubuntu 24.04+)"
}

speedtest_install_ookla_binary() {
  local arch tmp url bin_path
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" ;;
    aarch64|arm64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" ;;
    *)
      log_warn "Архитектура ${arch} не поддерживается для Ookla binary"
      return 1
      ;;
  esac
  tmp=$(mktemp -d)
  if ! curl -fsSL "$url" -o "$tmp/ookla-speedtest.tgz"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/ookla-speedtest.tgz" -C "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  bin_path="$tmp/speedtest"
  [ -x "$bin_path" ] || bin_path=$(find "$tmp" -maxdepth 2 -name speedtest -type f 2>/dev/null | head -1)
  if [ -z "$bin_path" ] || [ ! -f "$bin_path" ]; then
    rm -rf "$tmp"
    return 1
  fi
  install -m 755 "$bin_path" /usr/local/bin/speedtest
  rm -rf "$tmp"
  hash -r 2>/dev/null || true
  speedtest_is_ookla_installed
}

speedtest_install_ookla_pkg() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    if [ ! -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ] \
      && [ ! -f /etc/apt/sources.list.d/ookla-speedtest-cli.list ]; then
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || true
    fi
    speedtest_fixup_ookla_apt_repo
    if apt-get update -qq 2>/dev/null && apt-get install -y speedtest 2>/dev/null; then
      hash -r 2>/dev/null || true
      speedtest_is_ookla_installed && return 0
    fi
    log_warn "Установка Ookla через apt не удалась — пробую standalone binary"
  fi
  speedtest_install_ookla_binary
}

speedtest_install_ookla() {
  if speedtest_is_ookla_installed; then
    return 0
  fi
  if speedtest_is_legacy_installed; then
    if ! is_auto_mode; then
      confirm_action "Заменить устаревший speedtest-cli на официальный Ookla Speedtest?" || return 1
    else
      log_warn "Заменяю устаревший speedtest-cli на Ookla Speedtest"
    fi
    speedtest_remove_legacy
  elif ! is_auto_mode; then
    confirm_action "Установить Ookla Speedtest CLI для полного теста (download/upload/ping)?" || return 1
  fi
  if speedtest_install_ookla_pkg; then
    log_ok "Ookla Speedtest установлен: $(speedtest --version 2>&1 | head -1)"
    return 0
  fi
  log_warn "Не удалось установить Ookla Speedtest"
  return 1
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

speedtest_is_interactive() {
  [ -t 1 ] || { [ -e /dev/tty ] 2>/dev/null && [ -r /dev/tty ]; }
}

speedtest_log_step() {
  echo -e "${BOLD}[*]${NC} $*" >&2
}

speedtest_parse_ookla_human() {
  python3 -c 'import re, sys
text = sys.stdin.read()
if not text.strip():
    sys.exit(1)

def grab(pat):
    m = re.search(pat, text, re.I | re.M)
    return m.group(1).strip() if m else ""

dl = grab(r"Download:\s*([0-9][^\n]*)")
ul = grab(r"Upload:\s*([0-9][^\n]*)")
lat = grab(r"Latency:\s*([0-9][^\n]*)")
jit = grab(r"Jitter:\s*([0-9][^\n]*)")
srv = grab(r"Server:\s*([^\n]+)")
isp = grab(r"ISP:\s*([^\n]+)")
if not dl:
    sys.exit(1)
print(f"Download:  {dl}")
print(f"Upload:    {ul or \"н/д\"}")
print(f"Ping:      {lat or \"н/д\"}")
if jit:
    print(f"Jitter:    {jit}")
print(f"Server:    {srv or \"н/д\"}")
print(f"ISP:       {isp or \"н/д\"}")'
}

speedtest_run_json_report() {
  local mode_label="$1" raw json
  raw="$2"
  [ -n "$raw" ] || return 1
  json=$(printf '%s\n' "$raw" | speedtest_extract_json) || return 1
  echo -e "${BOLD}Режим: ${mode_label} ($(speedtest_ip_family_label))${NC}"
  printf '%s\n' "$json" | speedtest_parse_json || return 1
}

speedtest_curl_download() {
  local url="$1" max_time="$2" result
  speedtest_log_step "Download: ${url}"
  if speedtest_is_interactive; then
    result=$(speedtest_curl --progress-bar -o /dev/null -w '%{time_total} %{size_download}' \
      --max-time "$max_time" --retry 2 --retry-delay 1 "$url" 2>/dev/tty) && { printf '%s' "$result"; return 0; }
    result=$(curl -f --progress-bar -o /dev/null -w '%{time_total} %{size_download}' \
      --max-time "$max_time" --retry 2 --retry-delay 1 "$url" 2>/dev/tty) && { printf '%s' "$result"; return 0; }
    return 1
  fi
  result=$(speedtest_curl -fsSL -o /dev/null -w '%{time_total} %{size_download}' \
    --max-time "$max_time" --retry 2 --retry-delay 1 "$url" 2>/dev/null) && { printf '%s' "$result"; return 0; }
  result=$(curl -fsSL -o /dev/null -w '%{time_total} %{size_download}' \
    --max-time "$max_time" --retry 2 --retry-delay 1 "$url" 2>/dev/null) && { printf '%s' "$result"; return 0; }
  return 1
}

speedtest_curl_valid_result() {
  [[ "${1:-}" =~ ^[0-9.]+[[:space:]]+[0-9]+$ ]]
}

speedtest_curl_max_time() {
  case "${1:-quick}" in
    full|2) echo "180" ;;
    *) echo "60" ;;
  esac
}

speedtest_default_iface() {
  if [ "${SPEEDTEST_IP_FAMILY:-4}" = "6" ]; then
    ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
  else
    ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
  fi
}

speedtest_ookla_ip_args() {
  local bin help src iface
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 0
  help=$("$bin" --help 2>&1 || true)
  # Ookla 1.2.x: -i/--ip=ADDR binds a local IP; --ip=ipv4 is invalid and breaks on /32 VPS
  src=$(speedtest_primary_ip)
  if [ -n "$src" ] && printf '%s\n' "$help" | grep -qE '(^|[[:space:]])-i,[[:space:]]+--ip='; then
    echo -i "$src"
    return 0
  fi
  iface=$(speedtest_default_iface)
  if [ -n "$iface" ] && printf '%s\n' "$help" | grep -qE '(^|[[:space:]])-I,[[:space:]]+--interface='; then
    echo --interface="$iface"
  fi
}

speedtest_explain_ookla_failure() {
  local raw="$1"
  if [ -z "$raw" ]; then
    log_warn "Ookla: пустой ответ (таймаут или блокировка серверов speedtest.net)"
    return 0
  fi
  if printf '%s\n' "$raw" | grep -qi 'Failed binding local connection\|ConfigurationError\|Cannot retrieve configuration'; then
    log_warn "Ookla: ошибка конфигурации/сокета speedtest.net — пробую повтор или curl"
    return 0
  fi
  if printf '%s\n' "$raw" | grep -qi 'name resolution\|Cannot connect\|Connection refused\|timed out'; then
    log_warn "Ookla: нет доступа к серверам speedtest.net по $(speedtest_ip_family_label)"
    return 0
  fi
  speedtest_last_error_line "$raw"
}

speedtest_run_cmd() {
  local bin="$1" limit=180
  shift
  [ "$(basename "$bin")" = "speedtest" ] && limit=300
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

speedtest_run_ookla() {
  local raw bin tmp logf attempt ip_args last_result_raw=""
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  ip_args=$(speedtest_ookla_ip_args)
  tmp=$(mktemp)
  logf=$(mktemp)

  if ! speedtest_config_reachable; then
    speedtest_log_step "Ookla: конфиг speedtest.net недоступен по curl — пробую прямой замер..."
  else
    speedtest_log_step "Ookla Speedtest ($(speedtest_ip_family_label)): замер 1–3 мин (лог ниже)..."
  fi

  for attempt in 1 2 3; do
    if [ "$attempt" -gt 1 ]; then
      speedtest_log_step "Ookla: повтор ${attempt}/3 (пауза 5 с)..."
      sleep 5
    fi
    : >"$logf"
    if speedtest_is_interactive; then
      # shellcheck disable=SC2086
      speedtest_run_cmd "$bin" --accept-license --accept-gdpr $ip_args -f json 2>&1 | tee "$logf" >/dev/stderr || true
    else
      # shellcheck disable=SC2086
      speedtest_run_cmd "$bin" --accept-license --accept-gdpr $ip_args -f json >"$logf" 2>/dev/null || true
    fi
    raw=$(cat "$logf")
    if speedtest_run_json_report "Ookla Speedtest" "$raw"; then
      rm -f "$tmp" "$logf"
      return 0
    fi
    if speedtest_ookla_raw_has_result "$raw"; then
      last_result_raw="$raw"
      break
    fi
  done

  if [ -n "$last_result_raw" ]; then
    rm -f "$tmp" "$logf"
    speedtest_run_json_report "Ookla Speedtest" "$last_result_raw" && return 0
  fi

  # shellcheck disable=SC2086
  speedtest_run_cmd "$bin" --accept-license --accept-gdpr $ip_args -f json -o "$tmp" 2>/dev/null || true
  if [ -s "$tmp" ] && speedtest_extract_json <"$tmp" >/dev/null 2>&1; then
    raw=$(cat "$tmp")
    rm -f "$tmp" "$logf"
    speedtest_run_json_report "Ookla Speedtest" "$raw" && return 0
  fi

  rm -f "$tmp" "$logf"
  speedtest_explain_ookla_failure "$raw"
  return 1
}

speedtest_legacy_bind_args() {
  local src
  src=$(speedtest_primary_ip)
  [ -n "$src" ] && echo --source "$src"
}

speedtest_run_legacy() {
  local raw bin mini bind logf
  bin=$(speedtest_cli_bin)
  [ -n "$bin" ] || return 1
  bind=$(speedtest_legacy_bind_args)
  if ! speedtest_config_reachable; then
    speedtest_dns_diagnose || true
  fi
  speedtest_log_step "speedtest-cli: замер download/upload/ping..."
  logf=$(mktemp)
  # shellcheck disable=SC2086
  if speedtest_is_interactive; then
    speedtest_run_cmd "$bin" $bind --json 2>&1 | tee "$logf" >/dev/stderr || true
    raw=$(cat "$logf")
  else
    raw=$(speedtest_run_cmd "$bin" $bind --json 2>&1) || true
  fi
  rm -f "$logf"
  if speedtest_run_json_report "speedtest-cli" "$raw"; then
    return 0
  fi
  speedtest_log_step "speedtest-cli: повтор через HTTPS..."
  # shellcheck disable=SC2086
  raw=$(speedtest_run_cmd "$bin" $bind --json --secure 2>&1) || true
  if speedtest_run_json_report "speedtest-cli" "$raw"; then
    return 0
  fi
  while IFS= read -r mini; do
    [ -n "$mini" ] || continue
    speedtest_log_step "speedtest-cli mini: ${mini}"
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
        'https://proof.ovh.net/files/100Mb.dat' \
        'https://speed.cloudflare.com/__down?bytes=100000000' \
        'https://speed.cloudflare.com/__down?bytes=52428800'
      ;;
    *)
      printf '%s\n' \
        'https://proof.ovh.net/files/10Mb.dat' \
        'https://speed.cloudflare.com/__down?bytes=10485760'
      ;;
  esac
}

speedtest_run_fallback_download() {
  local profile="$1" url result time bytes mbit max_time
  max_time=$(speedtest_curl_max_time "$profile")
  echo -e "${BOLD}Режим: упрощённый (curl/Cloudflare, $(speedtest_ip_family_label))${NC}"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    result=$(speedtest_curl_download "$url" "$max_time") || continue
    speedtest_curl_valid_result "$result" || continue
    echo "" >&2
    time="${result%% *}"
    bytes="${result##* }"
    mbit=$(speedtest_format_mbit "$bytes" "$time")
    echo "Download:  ${mbit} Mbit/s  (${url})"
    return 0
  done < <(speedtest_fallback_urls "$profile")
  log_warn "Download: не удалось скачать тестовый файл — проверьте сеть и firewall"
  return 1
}

speedtest_run_fallback_upload() {
  local profile="$1" mb url time bytes mbit
  mb=$(speedtest_profile_upload_mb "$profile")
  bytes=$((mb * 1048576))
  url="https://speed.cloudflare.com/__up"
  speedtest_log_step "Upload: ~${mb} MB → ${url}"
  if speedtest_is_interactive; then
    time=$(dd if=/dev/zero bs=1M count="$mb" 2>/dev/null | speedtest_curl --progress-bar -o /dev/null -w '%{time_total}' \
      --max-time 120 --retry 3 --retry-delay 2 --retry-all-errors \
      -X POST -H "Content-Type: application/octet-stream" --data-binary @- "$url" 2>/dev/tty) || {
      echo "Upload:    н/д (cloudflare недоступен по $(speedtest_ip_family_label))"
      return 1
    }
  else
    time=$(dd if=/dev/zero bs=1M count="$mb" 2>/dev/null | speedtest_curl -fsSL -o /dev/null -w '%{time_total}' \
      --max-time 120 --retry 3 --retry-delay 2 --retry-all-errors \
      -X POST -H "Content-Type: application/octet-stream" --data-binary @- "$url" 2>/dev/null) || {
      echo "Upload:    н/д (cloudflare недоступен по $(speedtest_ip_family_label))"
      return 1
    }
  fi
  mbit=$(speedtest_format_mbit "$bytes" "$time")
  echo "Upload:    ${mbit} Mbit/s  (${url}, ~${mb} MB)"
}

speedtest_run_fallback_ping() {
  local host avg
  speedtest_log_step "Ping..."
  while IFS= read -r host; do
    if avg=$(ping -"${SPEEDTEST_IP_FAMILY:-4}" -c 4 -W 2 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5}'); then
      [ -n "$avg" ] && echo "Ping (${host}): ${avg} ms (avg)"
    fi
  done < <(speedtest_ping_targets)
}

run_speedtest() {
  local profile="${1:-quick}" dl_ok=0
  speedtest_detect_ip_family
  log_warn "Тест использует интернет-трафик ($(speedtest_ip_family_label), полный режим 1–2 мин)"
  if speedtest_is_ookla_installed || speedtest_install_ookla; then
    speedtest_run_full && return 0
    log_warn "Ookla недоступен (сеть/DNS speedtest.net) — упрощённый режим curl/Cloudflare"
  elif speedtest_is_legacy_installed; then
    log_warn "Установлен устаревший speedtest-cli — для полного теста выберите замену на Ookla"
    speedtest_run_legacy && return 0
    log_warn "Переключаюсь на упрощённый режим (curl + Cloudflare upload, $(speedtest_ip_family_label))"
  fi
  speedtest_run_fallback_download "$profile" && dl_ok=1
  speedtest_run_fallback_upload "$profile" || true
  speedtest_run_fallback_ping
  [ "$dl_ok" -eq 1 ] || return 1
}

# Backward-compatible aliases for smoke tests
speedtest_last_error_line() {
  local raw="$1" line
  line=$(printf '%s\n' "$raw" | grep -Evi '^\{|Auto-scaled prefix|auto-binary|auto-decimal' | grep -v '^[[:space:]]*$' | tail -1 || true)
  [ -n "$line" ] && log_warn "speedtest: ${line}"
}
speedtest_extract_ookla_json() { speedtest_extract_json; }
speedtest_parse_ookla_json() { speedtest_parse_json; }
