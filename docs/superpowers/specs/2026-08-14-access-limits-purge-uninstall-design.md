# telemt-deploy: device access limits + purge uninstall

**Date:** 2026-08-14  
**Status:** Approved (brainstorming)

## Goal

Add two operator-facing capabilities to telemt-deploy:

1. **Device / people limits on a single shared proxy link** — combo of telemt native `user_max_unique_ips` and `user_max_tcp_conns` for the `default` user.
2. **Full stack removal** — keep existing `--uninstall` behavior; add `--purge` and an interactive submenu for destructive cleanup including secret and TLS assets.

## Background

### Current uninstall (`lib/uninstall.sh`)

`--uninstall` and menu item 11 call `uninstall_all()`, which stops and removes core services (telemt, MEKO, zapret2, shaping) and nginx site configs, but intentionally preserves:

- `/root/telemt-secret.txt`
- Let's Encrypt certificates under `/etc/letsencrypt/`

It does **not** fully clean cluster panel/agent units, `/opt/telemt`, stub sites under `/var/www`, or all zapret2 paths in every edge case.

### Current access model

- Single shared secret via `[access.users] default = "<secret>"` in `templates/telemt.toml.tpl`
- Online “people” count in `lib/stats.sh` uses unique client IPs from `GET /v1/stats/users/active-ips`
- Menu item 13 provides per-IP **bandwidth** shaping (`lib/shaping.sh`), not connection/device count limits
- MTProxy / telemt does **not** receive a real device identifier from Telegram clients

### telemt native limits (relevant)

From telemt `CONFIG_PARAMS`:

| Parameter | Purpose |
|-----------|---------|
| `[access.user_max_unique_ips]` | Max distinct source IPs per named user |
| `[access.user_max_tcp_conns]` | Max concurrent TCP connections per named user |
| `user_max_unique_ips_mode` | Default `active_window` — tolerates brief IP changes (mobile roaming) |
| `user_max_unique_ips_window_secs` | Default `30` |

Operational note: one Telegram device typically opens **~3 TCP connections**. Safe minimum per device is **5** conn (headroom). Values below 5 can block even a single phone.

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| Link model | **A** — one shared link for everyone |
| Limit strategy | **C** — combo unique IPs + TCP connections |
| Uninstall modes | **B** — normal uninstall + separate full purge |

## Feature 1: Device access limits

### Approach

**Recommended: native telemt TOML limits** driven by a sidecar JSON config (same pattern as `lib/shaping.sh`).

Rejected:

- **External watchdog + iptables** — duplicates telemt, fragile, hard to maintain
- **Per-user secrets (multi-link)** — out of scope for v1 (user chose single link)

### Limit semantics (combo)

For user `default` (the shared link):

| telemt setting | Operator meaning | Default when enabled |
|----------------|------------------|----------------------|
| `user_max_unique_ips.default` | Anti-sharing: max distinct client IPs | `max_unique_ips` (default **5**) |
| `user_max_tcp_conns.default` | Device cap via TCP count | `max_tcp_conns` or `max_devices × 5` |

When `auto_tcp_from_devices` is true (default), `max_tcp_conns = max_devices × 5`.

**Minimum enforced `max_tcp_conns`:** 5.

**Disabled state:** remove `[access.user_max_unique_ips]` and `[access.user_max_tcp_conns]` blocks from generated TOML fragment (telemt treats missing maps as unlimited).

### Configuration

**Path:** `/etc/telemt/access-limits.json`

```json
{
  "enabled": false,
  "max_devices": 5,
  "max_unique_ips": 5,
  "max_tcp_conns": 25,
  "auto_tcp_from_devices": true
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Master switch |
| `max_devices` | integer ≥ 1 | Primary operator input; used when `auto_tcp_from_devices` is true |
| `max_unique_ips` | integer ≥ 1 | IP cap; defaults to `max_devices` if omitted on save |
| `max_tcp_conns` | integer ≥ 5 | TCP cap; auto-derived when `auto_tcp_from_devices` is true |
| `auto_tcp_from_devices` | boolean | When true, `max_tcp_conns = max_devices × 5` on save |

File mode `600`, root-owned. Lazy-created on first menu open or install hook.

### TOML application

**Template:** `templates/telemt-access-limits.toml.tpl`

```toml
[access.user_max_unique_ips]
default = ${ACCESS_MAX_UNIQUE_IPS}

[access.user_max_tcp_conns]
default = ${ACCESS_MAX_TCP_CONNS}
```

**Strategy:** After `telemt_write_config()` renders base `telemt.toml`, `access_limits_apply()` either:

1. Appends the limits fragment when `enabled=true`, or
2. Strips any existing limits sections when `enabled=false`

Use deterministic markers or rewrite only the tail fragment to avoid corrupting unrelated `[access]` keys.

**Apply:** `systemctl reload telemt` if supported; otherwise `systemctl restart telemt`. Verify service active after apply.

telemt may hot-reload config via `general.update_every`; restart/reload remains the installer’s explicit apply step for reliability.

### Menu (item 14)

New main menu entry: **14) Лимит устройств**

Submenu actions:

1. Enable / set max devices (prompt integer, default 5)
2. Show status: enabled flag, limits, active unique IPs, current TCP total from API
3. Advanced: set `max_unique_ips` and `max_tcp_conns` independently
4. Disable limits (set `enabled=false`, strip TOML sections, apply)
0. Back

Display caveats in UI (one screen, static text):

- Not a true device ID — approximation only
- Multiple phones on same Wi‑Fi share one IP
- Mobile roaming may briefly show 2 IPs for one device

### Stats integration

Extend `lib/stats.sh` header / snapshot when limits enabled:

```
лимит: 3/5 устройств (IP: 2/5, TCP: 9/25)
```

Counts from existing API helpers plus JSON config.

### Files

| File | Action |
|------|--------|
| `lib/access_limits.sh` | Create — JSON I/O, validation, TOML merge, apply |
| `templates/telemt-access-limits.toml.tpl` | Create |
| `lib/telemt.sh` | Modify — call `access_limits_apply` after `telemt_write_config` |
| `lib/menu.sh` | Modify — item 14 submenu |
| `lib/stats.sh` | Modify — show limit usage |
| `lib/doctor.sh` | Modify — verify JSON ↔ TOML consistency when enabled |
| `install.sh` | Modify — load module, bundle version check |
| `tests/access_limits_smoke.sh` | Create — offline validation / TCP derivation |
| `README.md` | Modify — document menu 14 |

### Error handling

- Invalid JSON → recreate defaults or fail with clear message
- `max_tcp_conns < 5` → reject with explanation
- telemt fails after apply → show `journalctl -u telemt -n 20`, do not silently revert JSON

## Feature 2: Purge uninstall

### Modes

| Mode | CLI | Keeps secret | Keeps LE certs |
|------|-----|--------------|----------------|
| Normal | `--uninstall` | Yes | Yes |
| Purge | `--uninstall --purge` | No | No |

### Normal uninstall (unchanged intent)

Existing `uninstall_all()` behavior preserved. Optional hardening: also stop/disable `telemt-panel`, `telemt-agent.timer`, `haproxy` when cluster role files present (idempotent).

### Purge extras (`uninstall_purge_extras()`)

Called when `PURGE=1` after normal uninstall steps:

| Target | Action |
|--------|--------|
| `$SECRET_FILE` (`/root/telemt-secret.txt`) | Delete |
| `$STATE_FILE` | Already deleted in normal path |
| `/etc/letsencrypt/live/$DOMAIN/` | `certbot delete --cert-name $DOMAIN` (best effort) |
| `/opt/telemt` | `rm -rf` |
| `/opt/telemt-panel` | `rm -rf` |
| `/opt/mtpr-simple` | Already removed in normal path |
| `/opt/tg-zapret2` | Covered by `zapret2_remove` |
| `/etc/telemt-deploy.cluster` | Delete |
| `/etc/systemd/system/telemt-panel.service` | Remove + daemon-reload |
| `/etc/systemd/system/telemt-agent.service` | Remove |
| `/etc/systemd/system/telemt-agent.timer` | Remove |
| `/var/www/telemt-stub-*` | Remove stub site dirs if present |
| `/usr/local/bin/tg` | `remove_tg_command` (already in normal path) |
| `userdel telemt` | Already in normal path |

Do **not** delete the cloned `~/tg` deploy repo unless operator explicitly requests (out of scope).

### Interactive menu (item 11)

Replace direct confirm with submenu:

```
=== Удаление ===
  1) Удалить стек (сохранить секрет и SSL)
  2) Полное удаление (секрет + сертификаты)
  0) Назад
```

Purge option requires **typed confirmation**: operator must enter `DELETE` or the configured domain name.

### CLI

```bash
sudo bash install.sh --uninstall          # normal
sudo bash install.sh --uninstall --purge  # full
```

`--purge` without `--uninstall` is rejected with usage hint.

### Files

| File | Action |
|------|--------|
| `lib/uninstall.sh` | Modify — `uninstall_purge_extras`, refactor `uninstall_all` |
| `lib/menu.sh` | Modify — uninstall submenu |
| `install.sh` | Modify — `PURGE` flag, help text |
| `README.md`, `INSTALL_INSTRUCTIONS.md` | Modify |

## Testing

### access_limits_smoke.sh (offline)

- TCP derivation: `max_devices=5` → `max_tcp_conns=25`
- Minimum clamp: `max_tcp_conns` never below 5
- TOML fragment contains expected integers when enabled
- Disabled state produces no limits sections

### Manual checklist

1. Enable limit 5 devices → telemt.toml has both sections → third distinct IP blocked under sharing test
2. Disable limits → sections removed → connections succeed
3. `--uninstall` → secret and certs remain
4. `--uninstall --purge` → secret and cert paths gone, no telemt units active
5. Menu 11 purge → requires typed `DELETE`

## Out of scope (v1)

- Per-person secrets / multiple links (brainstorm option B)
- IPv6 client limits
- Automatic scheduled purge
- Deleting the git clone directory on the server
- Runtime limit changes via undocumented telemt API (TOML + reload only)

## Success criteria

- Operator can cap shared-link usage with one menu action using combo IP + TCP limits
- UI explains limitations honestly
- Normal uninstall preserves secret and certs; purge removes them after explicit confirmation
- Doctor reports mismatch if JSON enabled but TOML sections missing
