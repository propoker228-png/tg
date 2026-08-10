# Remove RKN IP Registry Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completely remove RKN blocklist IP checking from telemt-deploy (module, CLI flag, install step, doctor step, tests, README).

**Architecture:** Atomic cleanup — delete `lib/rkn_check.sh` and strip every reference in `install.sh`, `version_picker.sh`, `doctor.sh`, `tests/smoke.sh`, and `README.md`. No stub module, no feature flag. Historical docs under `docs/superpowers/specs/` and `plans/` are not edited.

**Tech Stack:** Bash 5.x, existing smoke scripts (`tests/smoke.sh`, `tests/role_wizard_smoke.sh`), no pytest.

## Global Constraints

- Complete removal only — no optional/hidden RKN path
- Do not delete `/var/cache/telemt-deploy/rkn-ips.json` on servers (out of scope)
- Do not edit historical specs/plans (e.g. `2026-07-19-reliability-convenience-design.md`)
- Breaking change: `install.sh --check-rkn` must exit 1 with `Неизвестный аргумент: --check-rkn`
- Success: zero references to `rkn_check`, `check_rkn_ip`, `CHECK_RKN`, `--check-rkn` in tracked code
- Spec: `docs/superpowers/specs/2026-08-10-remove-rkn-check-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/rkn_check.sh` | Delete | RKN IP lookup module (entire file) |
| `install.sh` | Modify | CLI, module load, bundle check, early-exit |
| `lib/version_picker.sh` | Modify | Remove install-time RKN call |
| `lib/doctor.sh` | Modify | Remove RKN doctor checks |
| `tests/smoke.sh` | Modify | Remove RKN unit test |
| `README.md` | Modify | Remove `--check-rkn` from flags table |

---

### Task 1: Remove RKN module and `install.sh` wiring

**Files:**
- Delete: `lib/rkn_check.sh`
- Modify: `install.sh:20`, `install.sh:52`, `install.sh:86`, `install.sh:107`, `install.sh:123`, `install.sh:169`, `install.sh:231-234`, `install.sh:357-360`

**Interfaces:**
- Removes: `check_rkn_ip()`, `rkn_lookup_ip_in_cache()`, `RKN_CHECK_SH_VERSION`
- Removes: `CHECK_RKN` env/flag, `--check-rkn` CLI branch

- [ ] **Step 1: Delete the RKN module**

```bash
rm lib/rkn_check.sh
```

- [ ] **Step 2: Remove `--check-rkn` from install.sh header comment**

Delete line 20:

```bash
#   --check-rkn             Проверить IP сервера в реестре РКН (без меню)
```

- [ ] **Step 3: Remove CHECK_RKN from variable init**

Change line 52 from:

```bash
FRESH=0; KEEP_EXISTING=0; STATUS=0; MEKO_UPGRADE=0; CHECK_RKN=0; DOCTOR=0
```

to:

```bash
FRESH=0; KEEP_EXISTING=0; STATUS=0; MEKO_UPGRADE=0; DOCTOR=0
```

- [ ] **Step 4: Remove --check-rkn from argument parser**

Delete line 86:

```bash
    --check-rkn) CHECK_RKN=1; shift ;;
```

- [ ] **Step 5: Remove CHECK_RKN from export**

Change line 107 from:

```bash
export TELEMT_VERSION MEKO_VERSION MEKO_FULL YES FRESH KEEP_EXISTING MEKO_UPGRADE CHECK_RKN DOCTOR INSTALL_IP_ONLY
```

to:

```bash
export TELEMT_VERSION MEKO_VERSION MEKO_FULL YES FRESH KEEP_EXISTING MEKO_UPGRADE DOCTOR INSTALL_IP_ONLY
```

- [ ] **Step 6: Remove rkn_check from module load list**

Change line 123 — remove `rkn_check` from the `for mod in ...` list:

```bash
for mod in prereq dns nginx ssl ssl_renew telemt meko firewall dialog ui_highlight mask_picker version_picker sni_check haproxy cluster panel cluster_agent cluster_migrate cluster_panel role_wizard link backup doctor verify handoff uninstall env stats monitor install_flow cli_tools menu; do
```

- [ ] **Step 7: Remove CHECK_RKN from has_action_flags**

Change line 169 from:

```bash
  [ "$UNINSTALL" -eq 1 ] || [ "$STATUS" -eq 1 ] || [ "$CHECK_RKN" -eq 1 ] || [ "$FRESH" -eq 1 ] || \
```

to:

```bash
  [ "$UNINSTALL" -eq 1 ] || [ "$STATUS" -eq 1 ] || [ "$FRESH" -eq 1 ] || \
```

- [ ] **Step 8: Remove RKN_CHECK_SH_VERSION bundle check**

Delete lines 231-234:

```bash
  if [ "${RKN_CHECK_SH_VERSION:-}" != "1.0" ]; then
    echo "[X] Отсутствует lib/rkn_check.sh (v1.0) — скопируйте lib/rkn_check.sh на сервер" >&2
    missing=1
  fi
```

- [ ] **Step 9: Remove CHECK_RKN early-exit block**

Delete lines 357-360:

```bash
if [ "$CHECK_RKN" -eq 1 ]; then
  check_rkn_ip "$(get_public_ip)"
  exit $?
fi
```

- [ ] **Step 10: Verify install.sh syntax**

Run: `bash -n install.sh`
Expected: no output (exit 0)

- [ ] **Step 11: Commit**

```bash
git add -u lib/rkn_check.sh install.sh
git commit -m "refactor: remove RKN check module and install.sh wiring"
```

---

### Task 2: Remove RKN from install flow and doctor

**Files:**
- Modify: `lib/version_picker.sh:202`
- Modify: `lib/doctor.sh:52-63`, `lib/doctor.sh:129-136`

**Interfaces:**
- Consumes: `prepare_install_options()` flow unchanged except no RKN step
- Produces: `run_doctor_full()` without «РКН IP» row

- [ ] **Step 1: Remove RKN call from version_picker**

In `lib/version_picker.sh`, change `prepare_install_options()` — delete line 202:

```bash
  check_rkn_ip "$(get_public_ip)" || true
```

Resulting tail of function:

```bash
  prompt_ad_tag_colored
  print_install_summary
  confirm_action "Начать установку?" || die "Установка отменена"
}
```

- [ ] **Step 2: Remove doctor_check_rkn function**

Delete `lib/doctor.sh` lines 52-63:

```bash
doctor_check_rkn() {
  if check_rkn_ip "$(get_public_ip)" >/dev/null 2>&1; then
    doctor_record "РКН IP" pass "не в реестре"
  else
    local rc=$?
    if [ "$rc" -eq 1 ]; then
      doctor_record "РКН IP" fail "IP в реестре заблокированных"
    else
      doctor_record "РКН IP" warn "не удалось проверить"
    fi
  fi
}
```

- [ ] **Step 3: Remove inline RKN block from run_doctor_full**

In `lib/doctor.sh`, after `doctor_check_dns "$domain"`, delete lines 129-136:

```bash
  set +e
  check_rkn_ip "$(get_public_ip)" >/dev/null 2>&1
  case $? in
    0) doctor_record "РКН IP" pass "не в реестре" ;;
    1) doctor_record "РКН IP" fail "IP в реестре" ;;
    *) doctor_record "РКН IP" warn "проверка недоступна" ;;
  esac
  set -e
```

Next line should be `for svc in telemt nginx; do`.

- [ ] **Step 4: Verify syntax**

Run:

```bash
bash -n lib/version_picker.sh
bash -n lib/doctor.sh
```

Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add lib/version_picker.sh lib/doctor.sh
git commit -m "refactor: remove RKN checks from install flow and doctor"
```

---

### Task 3: Remove RKN smoke test and README entry

**Files:**
- Modify: `tests/smoke.sh:143-154`, `tests/smoke.sh:241`
- Modify: `README.md:70`

**Interfaces:**
- Removes: `check_rkn_ip_lookup()` smoke helper

- [ ] **Step 1: Remove check_rkn_ip_lookup function**

Delete `tests/smoke.sh` lines 143-154:

```bash
check_rkn_ip_lookup() {
  (
    # shellcheck source=../lib/rkn_check.sh
    source "$ROOT/lib/rkn_check.sh"
    local tmp="$ROOT/.tmp-smoke-rkn"
    mkdir -p "$tmp"
    printf '%s\n' '["90.156.254.235","10.0.0.0/8"]' > "$tmp/cache.json"
    [ "$(rkn_lookup_ip_in_cache "90.156.254.235" "$tmp/cache.json")" = "BLOCKED" ]
    [ "$(rkn_lookup_ip_in_cache "8.8.8.8" "$tmp/cache.json")" = "FREE" ]
    rm -rf "$tmp"
  )
}
```

- [ ] **Step 2: Remove check_cmd_ok registration**

Delete line 241:

```bash
check_cmd_ok "rkn ip cache lookup" check_rkn_ip_lookup
```

- [ ] **Step 3: Remove README table row**

Delete `README.md` line 70:

```markdown
| `--check-rkn` | Проверить IP сервера в реестре РКН (без меню) |
```

- [ ] **Step 4: Commit**

```bash
git add tests/smoke.sh README.md
git commit -m "docs: remove RKN check from smoke tests and README"
```

---

### Task 4: Final verification

**Files:**
- Verify: all tracked `.sh` and `README.md`

- [ ] **Step 1: Run smoke tests**

Run:

```bash
bash tests/smoke.sh
bash tests/role_wizard_smoke.sh
```

Expected: all checks pass

- [ ] **Step 2: Verify --check-rkn is gone from help**

Run:

```bash
bash install.sh --help
```

Expected: output does not contain `check-rkn`

- [ ] **Step 3: Verify --check-rkn is rejected**

Run:

```bash
bash install.sh --check-rkn 2>&1; echo exit:$?
```

Expected: `Неизвестный аргумент: --check-rkn` and `exit:1`

- [ ] **Step 4: Grep for leftover RKN references**

Run:

```bash
rg -n 'rkn_check|check_rkn_ip|CHECK_RKN|--check-rkn|RKN_CHECK' --glob '*.sh' --glob 'README.md' .
```

Expected: no matches (domain names like `rknmylove.botrkn.cloud-ip.cc` in smoke validators are OK — they are not RKN check code)

If matches found in `tests/smoke.sh` domain validator only (`rknmylove`), that is acceptable. Any match in `lib/`, `install.sh`, or `README.md` is a failure.

- [ ] **Step 5: Update spec status (optional)**

In `docs/superpowers/specs/2026-08-10-remove-rkn-check-design.md`, change:

```markdown
**Status:** Approved for implementation
```

to:

```markdown
**Status:** Implemented
```

- [ ] **Step 6: Final commit if spec status updated**

```bash
git add docs/superpowers/specs/2026-08-10-remove-rkn-check-design.md
git commit -m "docs: mark RKN removal spec as implemented"
```

---

## Spec Coverage Checklist

| Spec requirement | Task |
|------------------|------|
| Delete `lib/rkn_check.sh` | Task 1 |
| Remove `version_picker.sh` call | Task 2 |
| Remove `doctor_check_rkn` + inline block | Task 2 |
| Remove `install.sh` flag/wiring | Task 1 |
| Remove smoke test | Task 3 |
| Remove README row | Task 3 |
| `tests/smoke.sh` passes | Task 4 |
| No RKN references in code | Task 4 |
| Breaking change for `--check-rkn` | Task 1 + Task 4 |
| Out of scope: cache cleanup | N/A |
| Out of scope: historical docs | N/A |
