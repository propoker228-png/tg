# Per-IP Egress Traffic Shaping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add menu item 13 for per-client-IP egress bandwidth limiting (Mbit/s) with global default, per-IP overrides, and unlimited whitelist entries.

**Architecture:** `lib/shaping.sh` owns JSON config at `/etc/telemt/shaping.json`, limit resolution, and `tc` HTB apply. A standalone apply script runs from systemd on boot and every 30s via timer, syncing active IPs from telemt API. Menu item 13 in `lib/menu.sh` provides interactive CRUD on config and manual apply.

**Tech Stack:** Bash 5.x, Linux `tc` HTB (`iproute2`), telemt API (`lib/stats.sh`), systemd oneshot+timer, Python3 for JSON in tests.

## Global Constraints

- Egress to client only; speed in **Mbit/s**
- New active IPs auto-get global limit unless override exists
- Per-IP override `null` = unlimited (whitelist above global)
- Config path: `/etc/telemt/shaping.json`, mode `600`, root-owned
- Interface: `monitor_default_iface()` from `lib/monitor.sh`
- When disabled: restore `tc qdisc replace dev $IFACE root fq` (match `lib/prereq.sh`)
- When enabled: HTB root; **default class is unlimited**; only limited IPs get explicit filters (see Task 2 note)
- Timer: `OnBootSec=1min`, `OnUnitActiveSec=30s`
- `tests/shaping_smoke.sh` must not run `tc`, `systemctl`, or require root
- Warn when active IP count > 500
- Spec: `docs/superpowers/specs/2026-08-10-per-ip-traffic-shaping-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/shaping.sh` | Create | Config I/O, validation, `shaping_effective_limit`, `shaping_apply`, install units |
| `templates/telemt-shaping-apply.sh` | Create | Root entrypoint sourced from deploy tree |
| `templates/telemt-shaping.service` | Create | Boot apply oneshot |
| `templates/telemt-shaping.timer` | Create | 30s periodic sync |
| `lib/menu.sh` | Modify | Item 13 + `menu_shaping()` |
| `install.sh` | Modify | Load `shaping` module, version check |
| `lib/uninstall.sh` | Modify | Stop units, restore `fq`, remove apply script |
| `tests/shaping_smoke.sh` | Create | Offline unit tests |
| `tests/smoke.sh` | Modify | Syntax-check `shaping.sh` |
| `README.md` | Modify | Document menu item 13 |

---

### Task 1: Core shaping helpers + smoke tests (no tc)

**Files:**
- Create: `lib/shaping.sh`
- Create: `tests/shaping_smoke.sh`
- Modify: `tests/smoke.sh`

**Interfaces:**
- Produces: `SHAPING_SH_VERSION="1.0"`
- Produces: `SHAPING_CONFIG_FILE="/etc/telemt/shaping.json"`
- Produces: `shaping_effective_limit(ip, enabled, global_mbit, overrides_json) -> prints "unlimited" or mbit number`
- Produces: `shaping_mbit_to_tc_rate(mbit) -> prints e.g. "50mbit"`
- Produces: `shaping_validate_mbit(s) -> 0|1`
- Produces: `shaping_load_config` / `shaping_save_config` (use temp dir in tests via env override)

- [ ] **Step 1: Create failing smoke tests**

Create `tests/shaping_smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export SHAPING_CONFIG_FILE="$ROOT/.tmp-shaping-test/shaping.json"
mkdir -p "$(dirname "$SHAPING_CONFIG_FILE")"
rm -f "$SHAPING_CONFIG_FILE"

# shellcheck source=../lib/shaping.sh
source "$ROOT/lib/shaping.sh"

# effective_limit: global only
r=$(shaping_effective_limit "203.0.113.10" 1 50 '{}')
[ "$r" = "50" ] && pass "global limit" || fail "global limit got=$r"

# override custom
r=$(shaping_effective_limit "203.0.113.10" 1 50 '{"203.0.113.10":100}')
[ "$r" = "100" ] && pass "override custom" || fail "override custom got=$r"

# override unlimited (null)
r=$(shaping_effective_limit "203.0.113.10" 1 50 '{"203.0.113.10":null}')
[ "$r" = "unlimited" ] && pass "override unlimited" || fail "override unlimited got=$r"

# disabled
r=$(shaping_effective_limit "203.0.113.10" 0 50 '{}')
[ "$r" = "unlimited" ] && pass "disabled" || fail "disabled got=$r"

# global 0, no override
r=$(shaping_effective_limit "203.0.113.10" 1 0 '{}')
[ "$r" = "unlimited" ] && pass "global zero" || fail "global zero got=$r"

# tc rate string
[ "$(shaping_mbit_to_tc_rate 50)" = "50mbit" ] && pass "tc rate" || fail "tc rate"

# validate mbit
shaping_validate_mbit "10" && pass "valid mbit" || fail "valid mbit"
! shaping_validate_mbit "-1" && pass "reject negative" || fail "reject negative"
! shaping_validate_mbit "abc" && pass "reject abc" || fail "reject abc"

# config round-trip
shaping_save_config 1 50 '{"203.0.113.10":100}'
shaping_load_config
[ "${SHAPING_ENABLED:-0}" -eq 1 ] && [ "${SHAPING_GLOBAL_MBIT:-0}" = "50" ] && pass "config round-trip" || fail "config round-trip"

exit "$FAIL"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/shaping_smoke.sh`
Expected: FAIL (functions not found)

- [ ] **Step 3: Implement `lib/shaping.sh` helpers**

```bash
#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SHAPING_SH_VERSION="1.0"
SHAPING_CONFIG_FILE="${SHAPING_CONFIG_FILE:-/etc/telemt/shaping.json}"
SHAPING_APPLY_SCRIPT="/usr/local/bin/telemt-shaping-apply.sh"
SHAPING_CLASS_BASE=10

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
if ip in overrides:
    val = overrides[ip]
    if val is None:
        print("unlimited")
    else:
        print(int(val) if float(val) == int(float(val)) else val)
    raise SystemExit(0)
if global_mbit > 0:
    g = float(global_mbit)
    print(int(g) if g == int(g) else g)
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
    return 0
  fi
  eval "$(python3 - "$SHAPING_CONFIG_FILE" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
print(f"SHAPING_ENABLED={1 if data.get('enabled') else 0}")
print(f"SHAPING_GLOBAL_MBIT={data.get('global_mbit', 0)}")
import json as j
print("SHAPING_OVERRIDES_JSON=" + j.dumps(data.get('overrides') or {}))
PY
)"
  export SHAPING_ENABLED SHAPING_GLOBAL_MBIT SHAPING_OVERRIDES_JSON
}

shaping_save_config() {
  local enabled="$1" global_mbit="$2" overrides_json="$3"
  mkdir -p "$(dirname "$SHAPING_CONFIG_FILE")"
  python3 - "$SHAPING_CONFIG_FILE" "$enabled" "$global_mbit" "$overrides_json" <<'PY'
import json, sys, os
path, enabled, global_mbit, overrides_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {
    "enabled": enabled == "1",
    "global_mbit": float(global_mbit),
    "overrides": json.loads(overrides_json or "{}"),
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
}
```

- [ ] **Step 4: Add syntax check to `tests/smoke.sh`**

Ensure `lib/shaping.sh` is in the `for f in ... lib/*.sh` syntax loop (already globbed).

Add after other smoke script invocations:

```bash
bash "$ROOT/tests/shaping_smoke.sh" || FAIL=1
```

- [ ] **Step 5: Run tests**

Run: `bash tests/shaping_smoke.sh && bash tests/smoke.sh`
Expected: all OK

- [ ] **Step 6: Commit**

```bash
git add lib/shaping.sh tests/shaping_smoke.sh tests/smoke.sh
git commit -m "feat(shaping): add config helpers and offline smoke tests"
```

---

### Task 2: tc apply logic + apply script + systemd units

**Files:**
- Modify: `lib/shaping.sh` (add apply functions)
- Create: `templates/telemt-shaping-apply.sh`
- Create: `templates/telemt-shaping.service`
- Create: `templates/telemt-shaping.timer`

**Interfaces:**
- Consumes: `shaping_effective_limit`, `shaping_load_config`, `monitor_default_iface`, `fetch_active_ips_list`
- Produces: `shaping_apply() -> 0|1`
- Produces: `shaping_restore_fq(iface) -> void`
- Produces: `shaping_install_units() -> void`

**tc design note (spec clarification):** Default HTB class uses high rate (`1000mbit`) so unmatched traffic is unlimited. Only IPs with `effective_limit != unlimited` get explicit class+filter. This correctly implements per-IP whitelist (`null` override).

- [ ] **Step 1: Add apply functions to `lib/shaping.sh`**

```bash
shaping_restore_fq() {
  local iface="$1"
  [ -n "$iface" ] || return 0
  tc qdisc replace dev "$iface" root fq 2>/dev/null || true
}

shaping_collect_target_ips() {
  # Active IPs from API + any override keys (offline clients keep override in config)
  shaping_load_config
  python3 - "$SHAPING_OVERRIDES_JSON" <<'PY' | while IFS= read -r ip; do
import json, sys
for ip in json.loads(sys.argv[1] or "{}").keys():
    print(ip)
PY
    [ -n "$ip" ] && echo "$ip"
  done
  fetch_active_ips_list
}

shaping_apply() {
  local iface limit ip classid=0 mbit
  iface="$(monitor_default_iface)"
  [ -n "$iface" ] || { log_err "Интерфейс не найден"; return 1; }

  shaping_load_config
  if [ "${SHAPING_ENABLED:-0}" -ne 1 ]; then
    shaping_restore_fq "$iface"
    return 0
  fi

  # Full rebuild (idempotent)
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 999
  tc class add dev "$iface" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
  tc class add dev "$iface" parent 1:1 classid 1:999 htb rate 1000mbit ceil 1000mbit

  local -A seen=()
  local count=0
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    [ -n "${seen[$ip]+x}" ] && continue
    seen[$ip]=1
    count=$((count + 1))
    limit=$(shaping_effective_limit "$ip" "$SHAPING_ENABLED" "$SHAPING_GLOBAL_MBIT" "$SHAPING_OVERRIDES_JSON")
    [ "$limit" = "unlimited" ] && continue
    classid=$((SHAPING_CLASS_BASE + count))
    [ "$classid" -le 4095 ] || { log_warn "Слишком много IP для tc (>$((4095 - SHAPING_CLASS_BASE)))"; break; }
    mbit=$(shaping_mbit_to_tc_rate "$limit")
    tc class add dev "$iface" parent 1:1 classid "1:${classid}" htb rate "$mbit" ceil "$mbit"
    tc filter add dev "$iface" protocol ip parent 1:0 prio 1 u32 \
      match ip dst "$ip/32" flowid "1:${classid}"
  done < <(shaping_collect_target_ips | sort -u)

  [ "$count" -gt 500 ] && log_warn "Активных IP: ${count} — большая нагрузка на tc"
  return 0
}

shaping_install_units() {
  local deploy_root="${DEPLOY_ROOT:-/root/telemt-deploy}"
  install -m 755 "$deploy_root/templates/telemt-shaping-apply.sh" "$SHAPING_APPLY_SCRIPT"
  cp "$deploy_root/templates/telemt-shaping.service" /etc/systemd/system/telemt-shaping.service
  cp "$deploy_root/templates/telemt-shaping.timer" /etc/systemd/system/telemt-shaping.timer
  systemctl daemon-reload
  systemctl enable telemt-shaping.timer
  systemctl start telemt-shaping.timer
}
```

- [ ] **Step 2: Create apply script template**

`templates/telemt-shaping-apply.sh`:

```bash
#!/bin/bash
set -euo pipefail
DEPLOY_ROOT="${DEPLOY_ROOT:-/root/telemt-deploy}"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/stats.sh"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/monitor.sh"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/shaping.sh"
shaping_apply
```

- [ ] **Step 3: Create systemd units**

`templates/telemt-shaping.service`:

```ini
[Unit]
Description=Apply telemt per-IP egress traffic shaping
After=network-online.target telemt.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=DEPLOY_ROOT=/root/telemt-deploy
ExecStart=/usr/local/bin/telemt-shaping-apply.sh
RemainAfterExit=yes
```

`templates/telemt-shaping.timer`:

```ini
[Unit]
Description=Periodic telemt traffic shaping sync

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
Unit=telemt-shaping.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Syntax check**

Run: `bash -n lib/shaping.sh && bash -n templates/telemt-shaping-apply.sh`
Expected: no errors

- [ ] **Step 5: Commit**

```bash
git add lib/shaping.sh templates/telemt-shaping-apply.sh templates/telemt-shaping.service templates/telemt-shaping.timer
git commit -m "feat(shaping): add tc HTB apply and systemd units"
```

---

### Task 3: Menu item 13

**Files:**
- Modify: `lib/menu.sh`

**Interfaces:**
- Consumes: all `shaping_*` helpers from Task 1–2
- Produces: `menu_shaping()` interactive UI

- [ ] **Step 1: Add `menu_shaping()` to `lib/menu.sh`**

Implement submenu per spec (6 actions + list active IPs with effective limits). On first open, if config missing, call `shaping_save_config 0 0 '{}'`.

Key flows:
- **1 Global:** prompt Mbit/s, `shaping_validate_mbit`, set `enabled=1` if mbit>0, save, `shaping_apply`
- **2 Per-IP limit:** show numbered active IPs + manual entry; prompt mbit; update overrides JSON via python3; save; apply
- **3 Unlimited:** set `overrides[ip]=null`
- **4 Remove override:** delete key from overrides
- **5 Apply now:** `shaping_apply`
- **6 Disable:** `shaping_save_config 0 ...`, `shaping_apply`

Helper `shaping_format_ip_limit(ip)` prints e.g. `50 Mbit/s (глобальный)` / `без лимита (override)`.

- [ ] **Step 2: Wire main menu**

Add line after item 12:

```bash
echo "  13) Шейпинг трафика"
```

Add case:

```bash
13) menu_shaping ;;
```

- [ ] **Step 3: Manual smoke**

Run: `bash -n lib/menu.sh`
Expected: OK

- [ ] **Step 4: Commit**

```bash
git add lib/menu.sh
git commit -m "feat(menu): add item 13 traffic shaping submenu"
```

---

### Task 4: Install wiring, uninstall, README, integration

**Files:**
- Modify: `install.sh`
- Modify: `lib/uninstall.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-10-per-ip-traffic-shaping-design.md` (status → Implemented)

**Interfaces:**
- `install.sh` loads `shaping` in module list
- `shaping_install_units` called lazily on first menu open OR from `menu_shaping` first entry (v1: call `shaping_install_units` at end of `menu_shaping` if units missing)

- [ ] **Step 1: Wire `install.sh`**

Add `shaping` to module `for mod in ...` list (after `stats` or before `menu`).

Add bundle check:

```bash
if [ "${SHAPING_SH_VERSION:-}" != "1.0" ]; then
  echo "[X] Отсутствует lib/shaping.sh (v1.0)" >&2
  missing=1
fi
```

- [ ] **Step 2: Extend `lib/uninstall.sh`**

Before `systemctl daemon-reload`:

```bash
systemctl stop telemt-shaping.timer telemt-shaping.service 2>/dev/null || true
systemctl disable telemt-shaping.timer telemt-shaping.service 2>/dev/null || true
rm -f /etc/systemd/system/telemt-shaping.service /etc/systemd/system/telemt-shaping.timer
rm -f /usr/local/bin/telemt-shaping-apply.sh
iface=$(ip route | awk '/default/{print $5; exit}')
[ -n "$iface" ] && tc qdisc replace dev "$iface" root fq 2>/dev/null || true
```

(Config file removed with `rm -rf /etc/telemt` already in uninstall.)

- [ ] **Step 3: Lazy unit install in `menu_shaping`**

At start of `menu_shaping`, if `[ ! -f /etc/systemd/system/telemt-shaping.timer ]`, call `shaping_install_units`.

- [ ] **Step 4: Update README**

Add to interactive menu table:

| 13 | Шейпинг трафика (лимит Mbit/s на IP) |

Brief note: egress download limit per client IP, global + per-IP overrides.

- [ ] **Step 5: Run all smoke tests**

Run:

```bash
bash tests/shaping_smoke.sh
bash tests/smoke.sh
bash tests/role_wizard_smoke.sh
```

Expected: all pass (pre-existing failures excepted)

- [ ] **Step 6: Grep verification**

Run:

```bash
rg -n 'menu_shaping|shaping_apply|SHAPING_SH_VERSION' lib/ install.sh templates/
```

Expected: matches in expected files only

- [ ] **Step 7: Update spec status**

In `docs/superpowers/specs/2026-08-10-per-ip-traffic-shaping-design.md`:

```markdown
**Status:** Implemented
```

- [ ] **Step 8: Commit**

```bash
git add install.sh lib/uninstall.sh README.md docs/superpowers/specs/2026-08-10-per-ip-traffic-shaping-design.md
git commit -m "feat(shaping): wire install, uninstall, and docs for menu item 13"
```

---

## Spec Coverage Checklist

| Spec requirement | Task |
|------------------|------|
| `lib/shaping.sh` | 1, 2 |
| Config `/etc/telemt/shaping.json` | 1 |
| `effective_limit` logic | 1 |
| tc HTB apply | 2 |
| systemd service+timer | 2, 4 |
| Menu item 13 | 3 |
| install.sh module load | 4 |
| uninstall cleanup | 4 |
| `tests/shaping_smoke.sh` | 1 |
| README | 4 |
| Out of scope items | N/A |

## Manual integration test plan

1. `sudo bash install.sh` → menu 13 → set global 10 Mbit/s → apply
2. Connect client, run speed test → ~10 Mbit/s
3. Set override 100 Mbit/s for client IP → faster
4. Set same IP unlimited → no cap
5. Reboot VPS → limits persist
6. Disable shaping → `tc qdisc` shows `fq`
