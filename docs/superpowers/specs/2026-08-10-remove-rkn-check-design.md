# telemt-deploy: remove RKN IP registry check

**Date:** 2026-08-10  
**Status:** Implemented

## Goal

Remove all functionality that checks whether the server’s public IP appears in the Russian Roskomnadzor (RKN) blocklist. The installer must no longer download third-party RKN IP feeds, show RKN warnings during install, expose `--check-rkn`, or include an RKN step in `tg doctor`.

## Background

Current behavior (`lib/rkn_check.sh`):

- Downloads IP blocklists from `api.reserve-rbl.ru` and `reestr.rublacklist.net`
- Caches results at `/var/cache/telemt-deploy/rkn-ips.json` (TTL 6 hours)
- Falls back to per-IP export lookup when cache download fails
- Called during install prepare (`lib/version_picker.sh`) with `|| true` (non-blocking)
- Included as check #2 in `run_doctor_full()` (`lib/doctor.sh`)
- Available standalone via `install.sh --check-rkn`

The operator requested complete removal (not optional/hidden). Scope is limited to this change; other installer improvements are out of scope.

## Scope

### In scope

| File | Change |
|------|--------|
| `lib/rkn_check.sh` | Delete file |
| `lib/version_picker.sh` | Remove `check_rkn_ip "$(get_public_ip)" \|\| true` before install confirmation |
| `lib/doctor.sh` | Remove `doctor_check_rkn()` and the inline RKN block in `run_doctor_full()` |
| `install.sh` | Remove `--check-rkn`, `CHECK_RKN` variable, `rkn_check` module load, `RKN_CHECK_SH_VERSION` bundle check, and early-exit branch |
| `tests/smoke.sh` | Remove `check_rkn_ip_lookup` test and its `check_cmd_ok` registration |
| `README.md` | Remove `--check-rkn` from CLI flags table |

### Out of scope

- Deleting `/var/cache/telemt-deploy/rkn-ips.json` on existing servers (orphan cache is harmless)
- Editing historical specs/plans under `docs/superpowers/` (e.g. `2026-07-19-reliability-convenience-design.md`)
- Other installer features or refactors

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| Removal depth | Complete removal — delete module, flags, doctor step, tests, README |
| Spec scope | RKN removal only; other improvements later |

## Approach

**Atomic cleanup (recommended):** one change set that deletes `lib/rkn_check.sh` and removes every reference. No stub module, no feature flag.

Rejected alternatives:

- **Cache cleanup in uninstall** — useful but unrelated to removing the check
- **No-op stub** — contradicts complete-removal requirement

## Behavior after change

### Install flow

`prepare_install_options()` in `version_picker.sh` proceeds directly from `prompt_ad_tag_colored` to `print_install_summary` without network calls to RKN APIs.

### `tg doctor`

Full diagnostics skip the “РКН IP” row. Check order becomes: DNS → services → MEKO → port 443 → mask-site → link → SSL → SNI → SSL auto-renew.

`doctor_check_rkn()` is removed entirely (it was defined but only duplicated logic already inlined in `run_doctor_full`).

### CLI

- `install.sh --check-rkn` is removed from help and argument parser.
- **Breaking change:** scripts or cron jobs passing `--check-rkn` will fail with `Неизвестный аргумент: --check-rkn` (exit 1) because unknown arguments are rejected in `install.sh`.

### Module loading

Remove `rkn_check` from the `for mod in ...` list in `install.sh`. Remove `RKN_CHECK_SH_VERSION` from `require_lib_bundle()`.

## Implementation checklist

1. Delete `lib/rkn_check.sh`
2. Edit `lib/version_picker.sh` — remove line 202 (`check_rkn_ip ...`)
3. Edit `lib/doctor.sh` — remove `doctor_check_rkn()` and lines 129–136 in `run_doctor_full()`
4. Edit `install.sh`:
   - Remove header comment for `--check-rkn`
   - Remove `CHECK_RKN` init, parse case, export, `has_action_flags` condition
   - Remove `rkn_check` from module list
   - Remove `RKN_CHECK_SH_VERSION` check in `require_lib_bundle()`
   - Remove `if [ "$CHECK_RKN" -eq 1 ]` block
5. Edit `tests/smoke.sh` — remove `check_rkn_ip_lookup` function and `check_cmd_ok` line
6. Edit `README.md` — remove `--check-rkn` table row

## Testing

```bash
bash tests/smoke.sh
bash tests/role_wizard_smoke.sh
bash install.sh --help    # must not list --check-rkn
```

Manual (on Ubuntu server with existing install):

- Run `sudo bash install.sh` → install wizard shows no RKN step
- Run `sudo tg doctor` → no “РКН IP” line in output

## Risks

| Risk | Mitigation |
|------|------------|
| Cron/scripts use `--check-rkn` | Document breaking change; operator removes flag from automation |
| Stale cache file on disk | Harmless; optional future cleanup in uninstall if desired |

## Success criteria

- No file or code path references `rkn_check`, `check_rkn_ip`, `CHECK_RKN`, or `--check-rkn`
- `tests/smoke.sh` passes
- Install and doctor flows work without RKN-related output or external RKN API calls
