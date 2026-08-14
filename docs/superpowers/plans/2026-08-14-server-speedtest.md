# Server Internet Speed Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add menu item 15 and `--speedtest` CLI for on-demand server internet speed measurement (Ookla full mode + curl/ping fallback).

**Architecture:** New `lib/speedtest.sh` module owns Ookla detection/install, JSON parsing, curl download timing, and ping helpers. `run_speedtest(profile)` orchestrates: optional Ookla install prompt → Ookla run → fallback. Wired into `install.sh` early-exit branch and `lib/menu.sh` without `require_installed()`.

**Tech Stack:** Bash 5.x, Ookla `speedtest` CLI (optional apt install), `curl`, `ping`, Python3 for JSON parse in smoke tests.

## Global Constraints

- IPv4 only
- Does not require installed proxy or domain
- Does not stop telemt/nginx
- Fallback upload must show `н/д (требуется Ookla)` — never fake upload
- Ookla bandwidth JSON is bytes/sec → Mbit/s: `bytes * 8 / 1_000_000`
- Quick profile ~10 MB; full profile ~100 MB
- curl timeout 60s per URL
- `--speedtest --yes` auto-accepts Ookla install prompt
- `tests/speedtest_smoke.sh` must not use network or require root
- Spec: `docs/superpowers/specs/2026-08-14-server-speedtest-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/speedtest.sh` | Create | Core speed test logic |
| `tests/speedtest_smoke.sh` | Create | Offline unit tests |
| `install.sh` | Modify | `--speedtest`, module load, bundle check, early exit |
| `lib/menu.sh` | Modify | Item 15 + `menu_speedtest()` |
| `tests/smoke.sh` | Modify | Syntax check + smoke runner |
| `README.md` | Modify | Document menu 15 and CLI |

---

### Task 1: Core helpers + smoke tests

**Files:**
- Create: `lib/speedtest.sh`
- Create: `tests/speedtest_smoke.sh`
- Modify: `tests/smoke.sh`

**Interfaces:**
- Produces: `SPEEDTEST_SH_VERSION="1.0"`
- Produces: `SPEEDTEST_PROFILE_QUICK=quick` / `SPEEDTEST_PROFILE_FULL=full`
- Produces: `speedtest_format_mbit(bytes, seconds)` → prints e.g. `84.2`
- Produces: `speedtest_profile_bytes(profile)` → `10485760` or `104857600`
- Produces: `speedtest_parse_ookla_json(json_string)` → prints formatted lines (used by run in Task 2)

- [ ] **Step 1: Create failing smoke tests**

Create `tests/speedtest_smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# shellcheck source=../lib/speedtest.sh
source "$ROOT/lib/speedtest.sh"

r=$(speedtest_format_mbit 12500000 1)
[ "$r" = "100.0" ] && pass "format mbit 100" || fail "format mbit got=$r"

r=$(speedtest_profile_bytes quick)
[ "$r" = "10485760" ] && pass "profile quick bytes" || fail "quick bytes got=$r"

r=$(speedtest_profile_bytes full)
[ "$r" = "104857600" ] && pass "profile full bytes" || fail "full bytes got=$r"

out=$(speedtest_parse_ookla_json '{"download":{"bandwidth":12500000},"upload":{"bandwidth":6250000},"ping":{"latency":12.4,"jitter":1.2},"server":{"name":"Test","location":"Amsterdam"},"isp":"Test ISP"}')
echo "$out" | grep -q 'Download:.*100.0 Mbit/s' && pass "parse ookla download" || fail "parse ookla download"
echo "$out" | grep -q 'Upload:.*50.0 Mbit/s' && pass "parse ookla upload" || fail "parse ookla upload"
echo "$out" | grep -q 'Ping:.*12.4 ms' && pass "parse ookla ping" || fail "parse ookla ping"

exit "$FAIL"
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `bash tests/speedtest_smoke.sh`
Expected: module/functions not found

- [ ] **Step 3: Create `lib/speedtest.sh` helpers**

```bash
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
```

- [ ] **Step 4: Wire smoke into `tests/smoke.sh`**

Add `lib/speedtest.sh` to syntax loop and:
```bash
check_cmd_ok "speedtest smoke" bash "$ROOT/tests/speedtest_smoke.sh"
```

- [ ] **Step 5: Run smoke — expect PASS**

- [ ] **Step 6: Commit**

```bash
git add lib/speedtest.sh tests/speedtest_smoke.sh tests/smoke.sh
git commit -m "feat(speedtest): add core helpers and offline smoke tests"
```

---

### Task 2: Ookla install + run + fallback

**Files:**
- Modify: `lib/speedtest.sh`
- Modify: `tests/speedtest_smoke.sh` (optional: URL list helper if extracted)

**Interfaces:**
- Consumes: Task 1 helpers
- Produces: `speedtest_has_ookla()`, `speedtest_install_ookla()`, `speedtest_run_ookla()`, `speedtest_run_fallback_download(profile)`, `speedtest_run_fallback_ping()`, `run_speedtest(profile)`

- [ ] **Step 1: Add Ookla detection and install**

```bash
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
```

- [ ] **Step 2: Add Ookla run**

```bash
speedtest_run_ookla() {
  local json
  json=$(speedtest --accept-license --accept-gdpr --format=json 2>/dev/null) || return 1
  echo -e "${BOLD}Режим: Ookla Speedtest${NC}"
  speedtest_parse_ookla_json "$json"
}
```

- [ ] **Step 3: Add fallback download + ping**

```bash
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
      echo "Ping (${host}): ${avg} ms (avg)"
    fi
  done
}
```

- [ ] **Step 4: Add orchestrator**

```bash
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
```

- [ ] **Step 5: Manual test on Linux VPS** (optional if no VPS: skip, note in report)

- [ ] **Step 6: Commit**

```bash
git add lib/speedtest.sh
git commit -m "feat(speedtest): add Ookla install, run, and curl/ping fallback"
```

---

### Task 3: install.sh CLI wiring

**Files:**
- Modify: `install.sh`

**Interfaces:**
- Consumes: `run_speedtest` from Task 2

- [ ] **Step 1: Add flag and variable**

Header comment add:
```
#   --speedtest             Тест скорости интернета на сервере
```

```bash
SPEEDTEST=0
...
--speedtest) SPEEDTEST=1; shift ;;
```

Export: add `SPEEDTEST` to export line.

Module load list: add `speedtest` after `access_limits`.

Bundle check:
```bash
  if [ "${SPEEDTEST_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/speedtest.sh (v1.0)" >&2
    missing=1
  fi
```

- [ ] **Step 2: Early-exit branch** (after `MEKO_BENCHMARK`, before `UNINSTALL`)

```bash
if [ "$SPEEDTEST" -eq 1 ]; then
  run_speedtest "${SPEEDTEST_PROFILE:-quick}"
  exit $?
fi
```

- [ ] **Step 3: Update header menu range** `1–15`

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat(speedtest): wire --speedtest CLI flag"
```

---

### Task 4: Menu item 15

**Files:**
- Modify: `lib/menu.sh`

- [ ] **Step 1: Add `menu_speedtest()`**

```bash
menu_speedtest() {
  local c="" profile="quick"
  while true; do
    clear
    echo "=== Тест скорости интернета ==="
    echo "  1) Быстрый тест (~10 MB)"
    echo "  2) Полный тест (~100 MB)"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1) profile="quick"; break ;;
      2) profile="full"; break ;;
      0) return 0 ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
  run_speedtest "$profile"
  pause_key_menu
}
```

Note: **no** `require_installed()`.

- [ ] **Step 2: Add to main menu**

```bash
    echo "  15) Тест скорости интернета"
...
      15) menu_speedtest ;;
```

Update header comment in install.sh if says 1–14.

- [ ] **Step 3: Commit**

```bash
git add lib/menu.sh install.sh
git commit -m "feat(menu): add internet speed test item 15"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add section**

Document:
- Menu 15 (quick/full profiles)
- `sudo bash install.sh --speedtest`
- `sudo bash install.sh --speedtest --yes` (auto-install Ookla)
- Fallback mode limitations (upload н/д)
- Traffic warning

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document menu 15 and --speedtest"
```

---

## Manual verification checklist

- [ ] Menu 15 works without telemt installed
- [ ] Fallback shows download + ping, upload = н/д
- [ ] Ookla install + full report when accepted
- [ ] `--speedtest --yes` runs without prompts
- [ ] `bash tests/speedtest_smoke.sh` passes offline

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| Menu 15 no domain/proxy required | Task 4 |
| Ookla full mode | Task 2 |
| curl/ping fallback | Task 2 |
| `--speedtest` CLI | Task 3 |
| `--yes` for Ookla install | Task 2 (uses `is_auto_mode`) |
| Traffic warning | Task 2 `run_speedtest` |
| Offline smoke tests | Task 1 |
| README docs | Task 5 |
| Not in doctor (v1) | — (omitted by design) |
