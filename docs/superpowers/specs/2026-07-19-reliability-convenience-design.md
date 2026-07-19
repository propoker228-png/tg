# telemt-deploy: reliability and convenience (doctor, link, backup, SSL)

**Date:** 2026-07-19  
**Status:** Approved for implementation

## Goal

Extend telemt-deploy with reliability diagnostics and admin convenience commands, without Telegram auto-notifications in v1.

Deliverables:

1. **Full diagnostics** (`tg doctor`) — DNS, RKN, services, mask-site, proxy link, MEKO, SSL expiry, local SNI/TLS.
2. **Quick vs full checks** in menu item 9 (Проверки).
3. **Proxy link output** (`tg link`, optional QR).
4. **Full backup/restore** including Let's Encrypt certificates.
5. **Automatic SSL renewal hook** for certbot deploy.

Telegram bot alerts are explicitly **out of scope** for this iteration (deferred).

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| Priority areas | A (reliability) + B (convenience) |
| Telegram notifications | C — defer; only CLI commands now |
| Menu integration for doctor | C — item 9 stays; submenu: Quick / Full |
| Backup scope | C — secret, toml, state, nginx, MEKO, Let's Encrypt |

## Architecture

New modules (each `*_SH_VERSION=1.0`):

| Module | Responsibility |
|--------|----------------|
| `lib/doctor.sh` | Orchestrates quick/full diagnostic runs, aggregates pass/fail |
| `lib/sni_check.sh` | Local TLS handshake with configured SNI |
| `lib/link.sh` | Print proxy links; optional QR via `qrencode` |
| `lib/backup.sh` | Create/restore tar.gz archives |
| `lib/ssl_renew.sh` | Install certbot deploy hook; SSL days-until-expiry helper |

Existing modules updated:

| Module | Change |
|--------|--------|
| `lib/menu.sh` | Item 9 submenu: 1) Quick 2) Full (doctor) |
| `lib/verify.sh` | Quick path delegates to `run_doctor_quick` |
| `lib/install_flow.sh` | Call `ssl_install_renew_hook` after cert obtain |
| `install.sh` | Subcommand routing; `--doctor` flag; version 2.7 |
| `templates/tg` | Unchanged exec pattern — passes subcommands through |
| `tests/smoke.sh` | Offline tests for new helpers |

Recommended approach: **separate lib modules + `tg` subcommands** (not monolithic install.sh growth).

## `tg doctor` — full diagnostics

`run_doctor_full` runs all checks and prints a colored report. Each check returns pass/warn/fail without aborting the run. Final line: `✅ N/M passed`. Exit code equals number of failed checks (0 = all pass).

| # | Check | Implementation |
|---|-------|----------------|
| 1 | DNS domain → server IP | Reuse `validate_domain_dns` / dns helpers |
| 2 | IP in RKN registry | `check_rkn_ip` from `lib/rkn_check.sh` |
| 3 | telemt listens :443 | `telemt_listens_443` |
| 4 | mask-site HTTP 200 | `wait_mask_site_http` |
| 5 | Proxy link from API | `fetch_proxy_link` |
| 6 | MEKO / mtpr-synfix | `meko_show_version_info` + service status |
| 7 | SSL certificate expiry | `ssl_cert_days_left`; warn if &lt; 14 days |
| 8 | Local SNI/TLS | `check_sni_local` — openssl handshake to `:443` with SNI from `telemt.toml` |

**SNI limitation (explicit):** local check validates telemt/nginx TLS configuration only. It does **not** simulate Russian ISP DPI or @Sni_checker_bot marker detection. Doctor prints a hint to use @Sni_checker_bot for RU-side SNI marker checks.

### Quick check (`run_doctor_quick`)

Equivalent to current `verify_install`: services, 443, mask-site, link, online stats. Does **not** include RKN, SSL expiry deep check, or SNI probe.

### Menu item 9

```
=== Проверки ===
  1) Быстрая (verify)
  2) Полная (doctor)
  0) Назад
```

## `tg link`

```bash
sudo tg link
sudo tg link --qr
```

Behavior:

- Fetch TLS link via `fetch_proxy_link` (telemt API on `127.0.0.1:9091`).
- Print `tg://proxy?...` and `https://t.me/proxy?...` with colored labels.
- `--qr`: render QR in terminal if `qrencode` is installed; otherwise warn and show text only.
- If API unavailable: assemble link from `STATE_FILE` / `telemt.toml` (domain, secret) with documented fallback format.

`qrencode` is optional in `prereq_install` (recommended, not required).

## `tg backup` / `tg restore`

### Archive path

`/root/telemt-backup-YYYYMMDD-HHMMSS.tar.gz`

### Contents

| Archive path | Source |
|--------------|--------|
| `telemt-secret.txt` | `/root/telemt-secret.txt` |
| `telemt.toml` | `/etc/telemt/telemt.toml` |
| `telemt-deploy.state` | `/root/telemt-deploy.state` |
| `nginx/telemt-site` | `/etc/nginx/sites-available/telemt-site` (+ enabled symlink note in manifest) |
| `mtpr-simple/` | `/opt/mtpr-simple/` |
| `letsencrypt/live/DOMAIN/` | `/etc/letsencrypt/live/$DOMAIN/` (fullchain + privkey) |
| `MANIFEST.json` | metadata: domain, versions, timestamp, installer version |

### Commands

```bash
sudo tg backup
sudo tg restore /path/to/telemt-backup-....tar.gz
sudo tg restore /path/to/archive.tar.gz --force
```

Restore rules:

- Verify archive contains `MANIFEST.json`.
- Default: refuse restore if manifest domain ≠ current `DOMAIN` in state (unless `--force`).
- Stop services → extract files to original paths → `chmod`/`chown` as needed → restart `telemt`, `nginx`, `mtpr-synfix`.
- Never overwrite unrelated files outside manifest.

## SSL auto-renew

On install, write certbot deploy hook:

`/etc/letsencrypt/renewal-hooks/deploy/telemt-deploy.sh`

```bash
#!/bin/bash
systemctl reload nginx
systemctl restart telemt
```

Hook is idempotent; reinstall updates hook in place.

Menu item 6 (SSL) shows: `автообновление: включено` when hook exists.

Doctor check 7 warns when certificate expires in fewer than 14 days.

## CLI routing

`templates/tg` continues `exec bash "$DEPLOY_ROOT/install.sh" "$@"`.

`install.sh` handles subcommands before menu:

| Invocation | Action |
|------------|--------|
| `tg` / `install.sh` (no args, TTY) | main menu |
| `tg doctor` | `run_doctor_full` |
| `tg doctor --quick` | `run_doctor_quick` |
| `tg link [--qr]` | `show_proxy_link` |
| `tg backup` | `backup_create` |
| `tg restore FILE [--force]` | `backup_restore` |
| `install.sh --doctor` | `run_doctor_full` |
| `install.sh --check-rkn` | existing RKN check (unchanged) |

## Error handling

| Condition | Behavior |
|-----------|----------|
| Doctor check fails | Record fail; continue other checks |
| `tg link` API down | Fallback link from state/toml |
| Restore wrong domain | `die` unless `--force` |
| Missing `qrencode` | Text link only; `log_warn` |
| Backup missing files | Skip missing optional paths; fail if secret+toml absent |
| certbot hook write fails | `log_warn`; install continues |

## Testing

Extend `tests/smoke.sh` (no root, no network):

- `backup_manifest_lists_required_paths` — unit test manifest builder
- `ssl_cert_days_left` — mock cert or fixed date parsing
- `doctor_aggregate_exit_code` — mock checks returning pass/fail counts
- Bash syntax for all new `lib/*.sh`
- CLI: `install.sh --help` mentions new subcommands

Manual test checklist (documented in DEPLOY.md):

- `sudo tg doctor` on installed host
- `sudo tg link --qr`
- `sudo tg backup` + `sudo tg restore` round-trip on staging domain

## Non-goals

- Telegram notification bot / cron alerts
- Docker install profile
- External RU vantage DPI probing (only local SNI + bot hint)
- Replacing @Sni_checker_bot automation
- JSON output mode (future)

## Success criteria

- Menu item 9 offers Quick and Full diagnostics.
- `tg doctor` prints 8 checks with colored summary and non-zero exit on failures.
- `tg link` shows working proxy URL; `--qr` works when `qrencode` present.
- `tg backup` / `tg restore` round-trip restores proxy on same domain including TLS.
- certbot renew hook reloads nginx and restarts telemt.
- `bash tests/smoke.sh` passes without system changes.

## Version bump

- `INSTALLER_VERSION`: `2.6` → `2.7`
- Update `require_lib_bundle` checks for new module versions.
