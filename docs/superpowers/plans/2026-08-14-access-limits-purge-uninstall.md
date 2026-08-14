# Device Access Limits + Purge Uninstall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add menu item 14 for shared-link device limits (combo `user_max_unique_ips` + `user_max_tcp_conns` via telemt TOML) and add `--purge` full uninstall alongside existing `--uninstall`.

**Architecture:** `lib/access_limits.sh` mirrors `lib/shaping.sh`: JSON sidecar at `/etc/telemt/access-limits.json`, deterministic merge into `/etc/telemt/telemt.toml` using marker comments, then `systemctl restart telemt`. `lib/uninstall.sh` gains `uninstall_purge_extras()` invoked when `PURGE=1`; menu item 11 becomes a two-option submenu with typed `DELETE` confirmation for purge.

**Tech Stack:** Bash 5.x, telemt TOML (`templates/telemt-access-limits.toml.tpl`), telemt API (`lib/stats.sh`), Python3 for JSON, systemd, certbot (best-effort on purge).

## Global Constraints

- Single shared link only — user key is always `default` in telemt access maps
- Combo limits: `user_max_unique_ips.default` + `user_max_tcp_conns.default`
- `auto_tcp_from_devices=true` → `max_tcp_conns = max_devices × 5` on save
- Minimum `max_tcp_conns`: **5** (reject lower values in UI and save)
- Default enabled limits: `max_devices=5`, `max_unique_ips=5`, `max_tcp_conns=25`
- Config path: `/etc/telemt/access-limits.json`, mode `600`, root-owned
- TOML path: `/etc/telemt/telemt.toml`
- Marker block in TOML:
  - `# BEGIN telemt-deploy access limits`
  - `# END telemt-deploy access limits`
- `--purge` only valid with `--uninstall`
- Purge typed confirmation: operator must enter exactly `DELETE`
- Do not delete operator's git clone (`~/tg`) on purge
- `tests/access_limits_smoke.sh` must not run `systemctl`, `tc`, or require root
- Spec: `docs/superpowers/specs/2026-08-14-access-limits-purge-uninstall-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/access_limits.sh` | Create | JSON I/O, TCP derivation, TOML merge, apply, status formatting |
| `templates/telemt-access-limits.toml.tpl` | Create | Fragment for envsubst |
| `tests/access_limits_smoke.sh` | Create | Offline unit tests |
| `lib/telemt.sh` | Modify | Call `access_limits_apply` after `telemt_write_config` |
| `lib/menu.sh` | Modify | Item 14 `menu_access_limits()`; item 11 uninstall submenu |
| `lib/stats.sh` | Modify | Show limit usage in header when enabled |
| `lib/doctor.sh` | Modify | JSON ↔ TOML consistency check |
| `lib/uninstall.sh` | Modify | Cluster unit cleanup; `uninstall_purge_extras()` |
| `install.sh` | Modify | `PURGE` flag, load `access_limits`, bundle version check |
| `tests/smoke.sh` | Modify | Syntax-check new files; wire smoke runner |
| `README.md` | Modify | Menu 14 + `--purge` docs |
| `INSTALL_INSTRUCTIONS.md` | Modify | Uninstall modes |

---

### Task 1: Core access_limits helpers + smoke tests

**Files:**
- Create: `lib/access_limits.sh`
- Create: `tests/access_limits_smoke.sh`
- Modify: `tests/smoke.sh`

**Interfaces:**
- Produces: `ACCESS_LIMITS_SH_VERSION="1.0"`
- Produces: `ACCESS_LIMITS_CONFIG_FILE="/etc/telemt/access-limits.json"`
- Produces: `ACCESS_LIMITS_TCP_MULTIPLIER=5`
- Produces: `ACCESS_LIMITS_TCP_MIN=5`
- Produces: `access_limits_derive_tcp_conns(max_devices) -> prints integer >= 5`
- Produces: `access_limits_default_config() -> prints JSON`
- Produces: `access_limits_load_config` sets `ACCESS_LIMITS_ENABLED`, `ACCESS_LIMITS_MAX_DEVICES`, `ACCESS_LIMITS_MAX_UNIQUE_IPS`, `ACCESS_LIMITS_MAX_TCP_CONNS`, `ACCESS_LIMITS_AUTO_TCP`
- Produces: `access_limits_save_config(enabled, max_devices, max_unique_ips, max_tcp_conns, auto_tcp)`
- Produces: `access_limits_validate_positive_int(s) -> 0|1`
- Produces: `access_limits_validate_tcp_conns(s) -> 0|1` (integer >= 5)

- [ ] **Step 1: Create failing smoke tests**

Create `tests/access_limits_smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export ACCESS_LIMITS_CONFIG_FILE="$ROOT/.tmp-access-limits-test/access-limits.json"
mkdir -p "$(dirname "$ACCESS_LIMITS_CONFIG_FILE")"
rm -f "$ACCESS_LIMITS_CONFIG_FILE"

# shellcheck source=../lib/access_limits.sh
source "$ROOT/lib/access_limits.sh"

r=$(access_limits_derive_tcp_conns 5)
[ "$r" = "25" ] && pass "derive tcp 5 devices" || fail "derive tcp got=$r"

r=$(access_limits_derive_tcp_conns 1)
[ "$r" = "5" ] && pass "derive tcp min clamp" || fail "derive tcp min got=$r"

access_limits_save_config 1 5 5 25 1
access_limits_load_config
[ "${ACCESS_LIMITS_ENABLED:-0}" -eq 1 ] && pass "save/load enabled" || fail "enabled"
[ "${ACCESS_LIMITS_MAX_TCP_CONNS:-0}" -eq 25 ] && pass "save/load tcp" || fail "tcp"

access_limits_validate_positive_int 5 || fail "validate positive"
access_limits_validate_tcp_conns 4 && fail "reject tcp<5"
access_limits_validate_tcp_conns 5 || fail "accept tcp=5"

exit "$FAIL"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/access_limits_smoke.sh`
Expected: FAIL — `access_limits.sh` not found

- [ ] **Step 3: Create `lib/access_limits.sh`**

```bash
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
```

- [ ] **Step 4: Run smoke test**

Run: `bash tests/access_limits_smoke.sh`
Expected: all `OK:` lines, exit 0

- [ ] **Step 5: Wire into `tests/smoke.sh`**

Add syntax check for `lib/access_limits.sh` in the existing `for f in ...` loop and:

```bash
check_cmd_ok "access limits smoke" bash "$ROOT/tests/access_limits_smoke.sh"
```

- [ ] **Step 6: Commit**

```bash
git add lib/access_limits.sh tests/access_limits_smoke.sh tests/smoke.sh
git commit -m "feat(access-limits): add JSON config helpers and smoke tests"
```

---

### Task 2: TOML merge + apply

**Files:**
- Create: `templates/telemt-access-limits.toml.tpl`
- Modify: `lib/access_limits.sh`

**Interfaces:**
- Consumes: Task 1 helpers
- Produces: `access_limits_strip_toml(path)` — removes marker block if present
- Produces: `access_limits_render_fragment(unique_ips, tcp_conns) -> prints TOML fragment`
- Produces: `access_limits_merge_toml(path, enabled, unique_ips, tcp_conns)`
- Produces: `access_limits_apply()` — load config, merge TOML, restart telemt, verify active

- [ ] **Step 1: Add failing TOML merge test to `tests/access_limits_smoke.sh`**

Append:

```bash
tmp_toml="$ROOT/.tmp-access-limits-test/telemt.toml"
cat > "$tmp_toml" <<'EOF'
[access.users]
default = "abc"
EOF
ACCESS_LIMITS_TOML_FILE="$tmp_toml"
export ACCESS_LIMITS_TOML_FILE
access_limits_merge_toml "$tmp_toml" 1 5 25
grep -q 'user_max_unique_ips' "$tmp_toml" && pass "merge adds unique_ips" || fail "merge unique_ips"
grep -q 'default = 25' "$tmp_toml" && pass "merge adds tcp" || fail "merge tcp"
access_limits_merge_toml "$tmp_toml" 0 5 25
! grep -q 'user_max_unique_ips' "$tmp_toml" && pass "merge strips when disabled" || fail "strip"
```

- [ ] **Step 2: Run test — expect FAIL** (`access_limits_merge_toml` missing)

- [ ] **Step 3: Create template `templates/telemt-access-limits.toml.tpl`**

```toml
[access.user_max_unique_ips]
default = ${ACCESS_MAX_UNIQUE_IPS}

[access.user_max_tcp_conns]
default = ${ACCESS_MAX_TCP_CONNS}
```

- [ ] **Step 4: Implement merge functions in `lib/access_limits.sh`**

```bash
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
```

- [ ] **Step 5: Run `bash tests/access_limits_smoke.sh` — expect PASS**

- [ ] **Step 6: Commit**

```bash
git add templates/telemt-access-limits.toml.tpl lib/access_limits.sh tests/access_limits_smoke.sh
git commit -m "feat(access-limits): merge limits into telemt.toml with markers"
```

---

### Task 3: Wire install + telemt config path

**Files:**
- Modify: `lib/telemt.sh`
- Modify: `install.sh`

**Interfaces:**
- Consumes: `access_limits_apply` from Task 2
- Modifies: `telemt_write_config` tail to call `access_limits_apply`

- [ ] **Step 1: Update `lib/telemt.sh`**

At end of `telemt_write_config()` after `chmod 640`:

```bash
  if declare -f access_limits_apply >/dev/null 2>&1; then
    access_limits_apply
  fi
```

- [ ] **Step 2: Update `install.sh`**

Add to module load list (after `shaping`):

```bash
access_limits
```

Add variable and flag parsing:

```bash
PURGE=0
...
--purge) PURGE=1; shift ;;
```

After argument loop, before actions:

```bash
if [ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -ne 1 ]; then
  die "Флаг --purge можно использовать только вместе с --uninstall"
fi
export PURGE
```

In `require_lib_bundle()`:

```bash
  if [ "${ACCESS_LIMITS_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/access_limits.sh (v1.0)" >&2
    missing=1
  fi
```

In uninstall branch:

```bash
if [ "$UNINSTALL" -eq 1 ]; then
  ...
  uninstall_all
  exit 0
fi
```

(`uninstall_all` reads `$PURGE` internally — see Task 5.)

- [ ] **Step 3: Commit**

```bash
git add lib/telemt.sh install.sh
git commit -m "feat(access-limits): wire module into install and telemt config"
```

---

### Task 4: Menu item 14 — device limits UI

**Files:**
- Modify: `lib/access_limits.sh`
- Modify: `lib/menu.sh`

**Interfaces:**
- Produces: `access_limits_format_status_line() -> e.g. "лимит: 2/5 устройств (IP: 2/5, TCP: 6/25)"`
- Produces: `menu_access_limits()` interactive submenu

- [ ] **Step 1: Add `access_limits_format_status_line` to `lib/access_limits.sh`**

```bash
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
```

- [ ] **Step 2: Add `menu_access_limits()` to `lib/menu.sh`**

Main menu: add line `14) Лимит устройств` and case branch.

Submenu skeleton:

```bash
menu_access_limits() {
  local c="" devices="" ips="" tcp=""
  require_installed || return 0
  access_limits_ensure_config
  while true; do
    clear
    access_limits_load_config
    echo "=== Лимит устройств (общая ссылка) ==="
    access_limits_format_status_line
    echo ""
    echo "  Примечание: это приближение, не device ID."
    echo "  Несколько телефонов в одной Wi‑Fi = один IP."
    echo ""
    echo "  1) Включить / задать макс. устройств"
    echo "  2) Расширенные настройки (IP и TCP отдельно)"
    echo "  3) Выключить лимит"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1)
        prompt_line devices "Макс. устройств" "${ACCESS_LIMITS_MAX_DEVICES:-5}"
        access_limits_validate_positive_int "$devices" || { log_warn "Введите целое >= 1"; sleep 1; continue; }
        tcp=$(access_limits_derive_tcp_conns "$devices")
        access_limits_save_config 1 "$devices" "$devices" "$tcp" 1
        access_limits_apply && log_ok "Лимит включён: ${devices} устройств"
        ;;
      2)
        prompt_line ips "Макс. уникальных IP" "${ACCESS_LIMITS_MAX_UNIQUE_IPS:-5}"
        prompt_line tcp "Макс. TCP-соединений (мин. 5)" "${ACCESS_LIMITS_MAX_TCP_CONNS:-25}"
        access_limits_validate_positive_int "$ips" || { log_warn "IP: целое >= 1"; sleep 1; continue; }
        access_limits_validate_tcp_conns "$tcp" || { log_warn "TCP: минимум 5"; sleep 1; continue; }
        access_limits_save_config 1 "${ACCESS_LIMITS_MAX_DEVICES:-5}" "$ips" "$tcp" 0
        access_limits_apply && log_ok "Расширенные лимиты применены"
        ;;
      3)
        access_limits_save_config 0 "${ACCESS_LIMITS_MAX_DEVICES:-5}" "${ACCESS_LIMITS_MAX_UNIQUE_IPS:-5}" "${ACCESS_LIMITS_MAX_TCP_CONNS:-25}" "${ACCESS_LIMITS_AUTO_TCP:-1}"
        access_limits_apply && log_ok "Лимит выключен"
        ;;
      0) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}
```

- [ ] **Step 3: Manual smoke** — run `sudo bash install.sh`, open menu 14, enable 5 devices, verify `/etc/telemt/telemt.toml` contains marker block.

- [ ] **Step 4: Commit**

```bash
git add lib/access_limits.sh lib/menu.sh
git commit -m "feat(menu): add device access limits submenu (item 14)"
```

---

### Task 5: Purge uninstall backend

**Files:**
- Modify: `lib/uninstall.sh`
- Modify: `install.sh` (export `PURGE` — done in Task 3)

**Interfaces:**
- Produces: `uninstall_stop_extra_units()` — panel, agent, haproxy
- Produces: `uninstall_purge_extras()` — secret, certs, opt dirs, stub sites
- Modifies: `uninstall_all()` — call extras when `PURGE=1`

- [ ] **Step 1: Refactor `lib/uninstall.sh`**

Add near top:

```bash
uninstall_stop_extra_units() {
  systemctl stop telemt-panel telemt-agent.timer telemt-agent haproxy 2>/dev/null || true
  systemctl disable telemt-panel telemt-agent.timer telemt-agent haproxy 2>/dev/null || true
  rm -f /etc/systemd/system/telemt-panel.service \
        /etc/systemd/system/telemt-agent.service \
        /etc/systemd/system/telemt-agent.timer
}

uninstall_purge_extras() {
  env_load_settings 2>/dev/null || true
  rm -f "$SECRET_FILE"
  rm -f /etc/telemt-deploy.cluster
  rm -rf /opt/telemt /opt/telemt-panel
  rm -rf /var/www/telemt-stub-* 2>/dev/null || true
  if [ -n "${DOMAIN:-}" ] && command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
  fi
  log_warn "Purge: секрет и сертификаты удалены"
}
```

At start of `uninstall_all()` after log_warn, call `uninstall_stop_extra_units`.

Before final `log_ok`, add:

```bash
  if [ "${PURGE:-0}" -eq 1 ]; then
    uninstall_purge_extras
  fi
```

- [ ] **Step 2: Update uninstall CLI branch in `install.sh`**

```bash
if [ "$UNINSTALL" -eq 1 ]; then
  if ! is_auto_mode; then
    if [ "$PURGE" -eq 1 ]; then
      confirm_yes "ПОЛНОЕ удаление: секрет и SSL будут уничтожены. Продолжить?" || die "Отменено"
    else
      confirm_yes "Удалить установленный стек telemt-deploy?" || die "Удаление отменено"
    fi
  fi
  uninstall_all
  exit 0
fi
```

- [ ] **Step 3: Commit**

```bash
git add lib/uninstall.sh install.sh
git commit -m "feat(uninstall): add --purge full removal path"
```

---

### Task 6: Uninstall submenu + stats + doctor

**Files:**
- Modify: `lib/menu.sh`
- Modify: `lib/stats.sh`
- Modify: `lib/doctor.sh`

- [ ] **Step 1: Replace `menu_uninstall()` with submenu**

```bash
menu_uninstall() {
  local c="" confirm=""
  while true; do
    clear
    echo "=== Удаление ==="
    echo "  1) Удалить стек (сохранить секрет и SSL)"
    echo "  2) Полное удаление (секрет + сертификаты)"
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1)
        confirm_action "Удалить установленный стек?" || return 0
        PURGE=0 uninstall_all
        log_ok "Стек удалён (секрет и SSL сохранены)"
        pause_key_menu
        return 0
        ;;
      2)
        prompt_line confirm "Введите DELETE для подтверждения" ""
        [ "$confirm" = "DELETE" ] || { log_warn "Отменено"; sleep 1; continue; }
        PURGE=1 uninstall_all
        log_ok "Полное удаление завершено"
        pause_key_menu
        return 0
        ;;
      0) return 0 ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}
```

- [ ] **Step 2: Extend `render_menu_header` in `lib/stats.sh`**

After connections line, when `access_limits_format_status_line` exists and limits enabled:

```bash
  if declare -f access_limits_format_status_line >/dev/null 2>&1; then
    access_limits_load_config 2>/dev/null || true
    [ "${ACCESS_LIMITS_ENABLED:-0}" -eq 1 ] && echo "  $(access_limits_format_status_line)"
  fi
```

- [ ] **Step 3: Add doctor check in `lib/doctor.sh`**

In `run_doctor_full` after telemt checks:

```bash
  if declare -f access_limits_load_config >/dev/null 2>&1; then
    access_limits_load_config
    if [ "${ACCESS_LIMITS_ENABLED:-0}" -eq 1 ]; then
      if grep -q 'BEGIN telemt-deploy access limits' /etc/telemt/telemt.toml 2>/dev/null; then
        doctor_record "Access limits" pass "enabled, TOML block present"
      else
        doctor_record "Access limits" fail "JSON enabled but TOML block missing"
      fi
    else
      doctor_record "Access limits" pass "disabled"
    fi
  fi
```

- [ ] **Step 4: Commit**

```bash
git add lib/menu.sh lib/stats.sh lib/doctor.sh
git commit -m "feat: uninstall submenu, stats line, doctor access-limits check"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `INSTALL_INSTRUCTIONS.md`
- Modify: `install.sh` header comment (`--purge`, menu 14)

- [ ] **Step 1: README** — add menu item 14 description and CLI examples:

```bash
sudo bash install.sh --uninstall
sudo bash install.sh --uninstall --purge
```

Note: limits are approximate; min TCP 5.

- [ ] **Step 2: INSTALL_INSTRUCTIONS.md** — update section 12 with purge mode and menu 11 submenu.

- [ ] **Step 3: Commit**

```bash
git add README.md INSTALL_INSTRUCTIONS.md install.sh
git commit -m "docs: device limits menu 14 and purge uninstall"
```

---

## Manual verification checklist

- [ ] Menu 14: enable 5 devices → `/etc/telemt/access-limits.json` `enabled:true`, TOML has both access sections inside markers
- [ ] Menu 14: disable → markers and sections gone from TOML
- [ ] Header shows `лимит: X/5 ...` when enabled
- [ ] `sudo bash install.sh --uninstall` — secret file still exists
- [ ] `sudo bash install.sh --uninstall --purge` — secret gone, certbot delete attempted
- [ ] Menu 11 option 2 requires typing `DELETE`
- [ ] `bash tests/access_limits_smoke.sh` passes offline
- [ ] `bash tests/smoke.sh` passes offline

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| JSON sidecar config | Task 1 |
| Combo IP + TCP limits in TOML | Task 2 |
| Menu item 14 | Task 4 |
| Stats header line | Task 6 |
| Doctor JSON↔TOML check | Task 6 |
| `--uninstall` unchanged intent | Task 5 |
| `--uninstall --purge` | Task 3, 5 |
| Purge typed DELETE | Task 6 |
| Cluster/panel/agent unit cleanup | Task 5 |
| Out of scope items omitted | — |
