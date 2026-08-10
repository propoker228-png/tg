# telemt-deploy: per-IP egress traffic shaping (menu item 13)

**Date:** 2026-08-10  
**Status:** Approved for implementation

## Goal

Add interactive **per-client-IP egress bandwidth limiting** for telemt proxy traffic. Operators set a **global default** limit (Mbit/s) applied automatically to all client IPs (including newly connected ones), with optional **per-IP overrides** (custom Mbit/s or explicit unlimited). Exposed as **menu item 13** in `install.sh` / `tg` main menu.

## Background

Current behavior:

- Active client IPs come from telemt API: `GET /v1/stats/users/active-ips` (see `fetch_active_ips_list()` in `lib/stats.sh`)
- Menu item 2 shows active IPs as a read-only snapshot
- `lib/prereq.sh` sets `tc qdisc replace dev <iface> root fq` on the default route interface (BBR-friendly, no per-IP shaping)
- MEKO SYN FIX uses `iptables` hashlimit for SYN flood protection, not bandwidth shaping
- No traffic shaping configuration exists today

The operator wants manual control: set speed for all IPs and selectively for individual IPs.

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| Traffic direction | **Egress to client only** (download speed through proxy) |
| Speed units | **Mbit/s** |
| New IPs | **Auto-apply global limit** until per-IP override is set |
| Per-IP unlimited | **Yes** — override can set «без лимита» above global |
| Menu placement | **Item 13** in main menu |

## Approach

**Recommended: Linux `tc` HTB + per-destination-IP filters** on the default egress interface.

Rejected alternatives:

- **nftables meter/ratelimit** — packet-rate oriented, poor fit for stable Mbit/s bandwidth caps
- **External shaper daemon** — extra dependency, harder to maintain in installer

When shaping is **enabled**, replace root qdisc `fq` with `htb`. When **disabled**, restore `fq` as in `prereq.sh`.

## Effective limit resolution

```
effective_limit(IP):
  if overrides[IP] is null     → unlimited (no tc class for this IP)
  elif overrides[IP] > 0       → overrides[IP] Mbit/s
  elif global_mbit > 0         → global_mbit Mbit/s
  else                         → unlimited (shaping off)
```

- `global_mbit = 0` means no global cap (shaping disabled unless per-IP overrides exist)
- Removing a per-IP override reverts that IP to the global limit
- «Без лимита» for an IP stores `null` in overrides (explicit whitelist)

## Configuration

**Path:** `/etc/telemt/shaping.json`

**Schema:**

```json
{
  "enabled": true,
  "global_mbit": 50,
  "overrides": {
    "203.0.113.10": 100,
    "198.51.100.5": null
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Master switch; when false, remove shaping qdisc and restore `fq` |
| `global_mbit` | number ≥ 0 | Default egress cap in Mbit/s; `0` = no global cap |
| `overrides` | object | Keys: IPv4 strings; values: positive number (Mbit/s) or `null` (unlimited) |

File mode `600`, owned by root. Created on first menu use or during install hook (optional v1: lazy create on first open).

## Components

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/shaping.sh` | Create | Config load/save, validation, `effective_limit`, `tc` apply/sync |
| `lib/menu.sh` | Modify | Add item 13, `menu_shaping()` |
| `install.sh` | Modify | Load `shaping` module, bundle version check |
| `templates/telemt-shaping-apply.sh` | Create | Root script: read config, apply/remove `tc` rules |
| `templates/telemt-shaping.service` | Create | `After=network-online.target telemt.service`; runs apply on boot |
| `templates/telemt-shaping.timer` | Create | Periodic sync (default 30s) with active-ips |
| `lib/install_flow.sh` or `lib/handoff.sh` | Modify | Install systemd units on deploy (if not lazy) |
| `lib/uninstall.sh` | Modify | Remove units, restore `fq`, delete config (optional: keep config) |
| `tests/shaping_smoke.sh` | Create | Offline tests: JSON, `effective_limit`, validators |
| `tests/smoke.sh` | Modify | Syntax check `shaping.sh` |
| `README.md` | Modify | Document menu item 13 |

## `tc` implementation

**Interface:** same as `monitor_default_iface()` in `lib/monitor.sh` (default route `dev`).

**When enabled (`enabled=true` and at least one IP needs a limit):**

1. `tc qdisc replace dev $IFACE root handle 1: htb default 999`
2. Root class `1:1` — ceiling = sum of child rates + headroom (or interface practical max)
3. Default class `1:999` — rate = `global_mbit` (if > 0)
4. Per limited IP `X.X.X.X`: class `1:<id>`, rate = effective Mbit/s, filter `u32 match ip dst X.X.X.X/32 flowid 1:<id>`
5. Unlimited IPs: no filter (traffic falls through to default class only if global applies; if global=0 and IP is unlimited, no shaping for that IP)

**Class ID allocation:** stable hash or sequential counter stored in apply state; regenerated on each full apply (idempotent full rebuild).

**When disabled:** `tc qdisc replace dev $IFACE root fq` (match `prereq.sh`).

**Dependencies:** package `iproute2` (already installed via `ip`/`tc` on Ubuntu); no new apt packages required.

## Sync with active IPs

Timer/service calls `shaping_sync_active_ips()`:

1. Fetch IPs via `fetch_active_ips_list()` (telemt API)
2. For each IP, compute `effective_limit`
3. Ensure `tc` class+filter exists for each limited IP
4. Remove `tc` rules for IPs no longer active **only if** they have no override in config (overrides persist in JSON even when IP offline)

Rationale: overrides stay in config for known clients; active-ips drives which filters are currently installed for connected clients.

## Menu item 13 — `menu_shaping()`

Requires `require_installed` (telemt must be installed).

```
=== Шейпинг трафика (исходящий, Mbit/s) ===
  Интерфейс: eth0
  Глобальный лимит: 50 Mbit/s
  Статус: включён

  Активные IP:
    203.0.113.10   50 Mbit/s (глобальный)
    198.51.100.5   без лимита (override)
    192.0.2.7      100 Mbit/s (индивидуальный)

  1) Задать глобальный лимит (Mbit/s, 0 = выкл)
  2) Задать лимит для IP
  3) Снять лимит с IP (без лимита)
  4) Убрать индивидуальный override
  5) Применить правила сейчас
  6) Выключить шейпинг полностью
  0) Назад
```

**Sub-flow 2:** prompt IP (validate IPv4) or pick from numbered active list; prompt Mbit/s (positive integer/float, max e.g. 10000).

**Sub-flow 3:** set `overrides[IP] = null`.

**Sub-flow 4:** delete key from `overrides`.

**Sub-flow 5:** call `shaping_apply` immediately, show success/fail.

**Sub-flow 6:** `enabled=false`, `shaping_apply`, restore `fq`.

Main menu label: `13) Шейпинг трафика`.

## Error handling

| Condition | Behavior |
|-----------|----------|
| `tc` command fails | `log_err`, show stderr hint; config still saved |
| telemt API unreachable during sync | apply rules for configured overrides only; warn once |
| Invalid IP input | reject, re-prompt |
| Invalid Mbit/s (negative, non-numeric) | reject |
| Not root | menu requires `sudo` / root (same as other menu items) |
| \>500 active IPs | `log_warn` about tc scalability; continue |

## Persistence and lifecycle

- Config survives reboot
- `telemt-shaping.service` — `Type=oneshot`, `RemainAfterExit=yes`, runs apply on boot
- `telemt-shaping.timer` — `OnBootSec=1min`, `OnUnitActiveSec=30s`, triggers apply script
- `uninstall.sh` — stop/disable timer+service, remove units, `tc qdisc replace ... fq`, optionally keep `/etc/telemt/shaping.json` (v1: remove with `--fresh` uninstall only; normal uninstall removes units and restores qdisc)

## Testing

**Offline (`tests/shaping_smoke.sh`):**

- `effective_limit` for global-only, override, unlimited override, disabled
- JSON round-trip read/write
- IPv4 validation
- Mbit/s → `tc` rate string conversion (e.g. `50` → `50mbit`)

**Integration (manual on Ubuntu VPS):**

- Set global 10 Mbit/s, verify with speed test from client
- Set per-IP override 100 Mbit/s, verify difference
- Set per-IP unlimited, verify no cap vs global-limited IP
- Reboot, confirm limits persist
- Disable shaping, confirm `fq` restored

**CI-safe:** `tests/shaping_smoke.sh` must not run `tc`, `systemctl`, or require root.

## Out of scope (v1)

- Ingress (upload) limiting
- IPv6 clients
- Cluster master_lb / HAProxy-level shaping
- Web panel (:8443) integration
- Dynamic auto-tuning based on CPU/load
- Per-TCP-connection limits (only per unique client IP)

## Risks

| Risk | Mitigation |
|------|------------|
| Root qdisc change breaks BBR/fq | Restore `fq` when disabled; document that shaping replaces `fq` while active |
| Many active IPs → large tc filter set | Warn at 500; full rebuild on each apply keeps logic simple |
| API lists proxy peer IPs not end-users | Same source as menu stats; operator sees same IPs as item 2 |
| Shaping wrong interface on multi-homed VPS | Use `monitor_default_iface()`; show iface in menu header |

## Success criteria

- Menu item 13 available after install
- Global limit auto-applies to new active IPs
- Per-IP override and per-IP unlimited work as specified
- Settings persist across reboot via systemd
- `tests/shaping_smoke.sh` passes without root
- README documents feature briefly
