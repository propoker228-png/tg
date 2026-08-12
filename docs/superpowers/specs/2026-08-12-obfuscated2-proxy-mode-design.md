# telemt-deploy: Obfuscated2 (secure/dd) proxy mode for standalone

**Date:** 2026-08-12  
**Status:** Implemented

## Goal

Add the ability to deploy a **standalone** Telegram MTProxy in **Obfuscated2 mode** (`dd` secret prefix) as an alternative to the current default **Fake TLS mode** (`ee` secret prefix). Exactly **one mode per server** — chosen at install time. Cluster roles (`node`, `master_lb`) remain Fake TLS only.

## Background

Current installer behavior:

- `templates/telemt.toml.tpl` hardcodes `[general.modes]`: `tls=true`, `secure=false`, `classic=false`
- Proxy links use `ee` + 32-hex secret + TLS domain hex (`lib/link.sh`, `fetch_proxy_link()` reads `links.tls[0]`)
- Full stack: telemt on 443 + nginx self-mask on `127.0.0.1:8444` + Let's Encrypt + MEKO SYN FIX
- `[censorship]` enables mask relay and TLS emulation for Fake TLS

Telegram/MTProxy modes (telemt implements all three):

| Prefix | telemt `[general.modes]` | Link secret format |
|--------|--------------------------|-------------------|
| (none) | `classic=true` | 32 hex only — deprecated, out of scope |
| `dd` | `secure=true`, `tls=false` | `dd` + 32 hex — **Obfuscated2** (random padding) |
| `ee` | `tls=true`, `secure=false` | `ee` + 32 hex + domain hex — **Fake TLS** (current default) |

Reference: [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) (dd prefix on client side), [telemt CONFIG_PARAMS](https://github.com/telemt/telemt/blob/main/docs/Config_params/CONFIG_PARAMS.en.md).

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| Coexistence with Fake TLS | **A** — either `ee` or `dd` per server, not both as primary install choice |
| Stack for Obfuscated2 | **A1** — full stack unchanged (nginx + Let's Encrypt + MEKO) |
| Scope | **B1** — standalone only; cluster stays Fake TLS |

## Recommended approach

**Single template with envsubst variables** (approach 1): extend `telemt.toml.tpl` with `${MODE_TLS}` / `${MODE_SECURE}` and conditional `TLS_EMULATION`, matching the existing pattern for `${TLS_EMULATION}`. Avoid duplicate templates or programmatic TOML generation.

## Architecture

### Mode selection UX

Prompt **only for standalone** role, after domain/IP setup, before telemt/MEKO version picker (inside `prepare_install_options()`):

```
=== Режим прокси ===
  1) Fake TLS (ee) — рекомендуется, маскировка под HTTPS
  2) Obfuscated2 (dd) — random padding, без Fake TLS
```

Default: **1 (Fake TLS)** for backward compatibility.

### CLI

```
--proxy-mode MODE    tls (default, Fake TLS) | secure (Obfuscated2/dd)
                     Standalone only. Ignored for cluster roles with log_warn.
```

Examples:

```bash
sudo bash install.sh --domain example.com --yes
sudo bash install.sh --domain example.com --proxy-mode=secure --yes
```

### State persistence

Add to `/root/telemt-deploy.state`:

```
PROXY_MODE=tls    # or secure
```

Missing field on old installs → treat as `tls`.

### Install flow

No change to step order:

```
prereq → nginx temp → certbot → nginx production → telemt → meko → firewall → verify
```

Only `telemt.toml` content and output link format differ by mode.

## telemt.toml by mode

Single template `templates/telemt.toml.tpl`:

| Parameter | Fake TLS (`tls`) | Obfuscated2 (`secure`) |
|-----------|------------------|------------------------|
| `[general.modes].tls` | `true` | `false` |
| `[general.modes].secure` | `false` | `true` |
| `[general.modes].classic` | `false` | `false` |
| `[censorship].tls_emulation` | current logic | `false` |
| `[censorship].mask` | `true` | `true` |
| `[censorship].mask_host` / `mask_port` | `127.0.0.1:8444` | unchanged |
| `[censorship].tls_domain` | `TLS_DOMAIN` | `TLS_DOMAIN` (nginx mask backend) |
| nginx / certbot / MEKO | full stack | full stack (unchanged) |

`render_template()` in `lib/common.sh` exports:

- `MODE_TLS` / `MODE_SECURE` from `PROXY_MODE`
- `TLS_EMULATION=false` when `PROXY_MODE=secure` (keep existing rules for ip-only / split-domain when `tls`)

## Link generation

| Mode | Format |
|------|--------|
| Fake TLS | `tg://proxy?server=DOMAIN&port=443&secret=ee{SECRET}{DOMAIN_HEX}` |
| Obfuscated2 | `tg://proxy?server=DOMAIN&port=443&secret=dd{SECRET}` |

### Code changes

| File | Change |
|------|--------|
| `lib/common.sh` → `fetch_proxy_link()` | Use `links.secure[0]` when `PROXY_MODE=secure`, else `links.tls[0]` |
| `lib/link.sh` → `build_proxy_link_fallback()` | `dd` prefix without domain hex when secure |
| `lib/env.sh` | Load `PROXY_MODE` from state (default `tls`) |
| `lib/telemt.sh` | Export mode vars before template render |
| `lib/panel_api.py` | **No change** — cluster panel stays Fake TLS |

Primary link source remains telemt API (`127.0.0.1:9091/v1/users`); fallback used when API unavailable.

## New module: `lib/proxy_mode.sh`

```bash
PROXY_MODE="${PROXY_MODE:-tls}"   # tls | secure

normalize_proxy_mode()    # validate CLI value; die on invalid
proxy_mode_is_secure()    # test PROXY_MODE=secure
proxy_mode_label()        # human label for summaries
proxy_mode_link_kind()    # "tls" | "secure" for API JSON key
pick_proxy_mode()         # interactive; standalone only
proxy_mode_force_tls_for_cluster()  # reset + warn if cluster role
```

Sourced from `install.sh` with other `lib/*.sh` modules.

## Verification

| Check | Fake TLS | Obfuscated2 |
|-------|----------|-------------|
| telemt / nginx active | yes | yes |
| port 443 listening | yes | yes |
| mask site HTTP 200 | yes | yes |
| link from API | `links.tls[0]` | `links.secure[0]` |
| SNI-specific doctor steps | as today | skip / N/A |

## Migration and constraints

| Scenario | Behavior |
|----------|----------|
| Old state without `PROXY_MODE` | Default `tls` |
| `--keep` | No mode change |
| `--fresh` reinstall standalone | New mode selectable |
| In-place `ee` → `dd` without `--fresh` | **Not supported in v1** — requires reinstall; breaks client links |
| `--proxy-mode=secure --role=node` | Force `tls`, `log_warn` |
| Invalid `--proxy-mode` | `die` with allowed values |

## UI summaries

- `print_install_summary()` — add line: `Режим: Fake TLS (ee)` or `Obfuscated2 (dd)`
- `print_role_summary()` standalone — same line
- Optional: main menu header shows mode when `PROXY_MODE=secure`

## Files to modify

| File | Action |
|------|--------|
| `lib/proxy_mode.sh` | **Create** |
| `templates/telemt.toml.tpl` | Parameterize modes |
| `lib/common.sh` | `render_template`, `fetch_proxy_link`, `save_state` |
| `lib/telemt.sh` | Mode exports in `telemt_write_config` |
| `lib/link.sh` | Mode-aware fallback link |
| `lib/env.sh` | Load `PROXY_MODE` |
| `lib/version_picker.sh` | Call `pick_proxy_mode()` in `prepare_install_options` |
| `lib/ui_highlight.sh` | Summary line |
| `lib/role_wizard.sh` | Role summary line |
| `install.sh` | `--proxy-mode`, help, source module |
| `README.md` | Document flag and modes |
| `DEPLOY.md` | Example secure install |
| `tests/proxy_mode_smoke.sh` | **Create** offline tests |
| `tests/smoke.sh` | Invoke new smoke |

**Out of scope (unchanged):** `lib/cluster.sh`, `lib/panel_api.py`, `lib/haproxy.sh`, cluster menu flows.

## Testing

New `tests/proxy_mode_smoke.sh` (no root, no apt):

- `normalize_proxy_mode` accepts `tls`/`secure`, rejects garbage
- Template render: secure → `secure=true`, `tls=false`, `tls_emulation=false`
- Template render: tls → no regression vs current defaults
- `build_proxy_link_fallback`: `dd` + secret only; `ee` + domain hex
- `proxy_mode_link_kind` returns correct API key

Run via `bash tests/smoke.sh`.

Manual test plan (on Ubuntu server with domain):

1. `install.sh --domain DOMAIN --proxy-mode=secure --yes`
2. `tg link` → secret starts with `dd`
3. Connect Telegram client
4. `tg doctor --quick` passes
5. Regression: default install still produces `ee` link

## Error handling

- Unknown `--proxy-mode` → die with allowed values
- Cluster + `--proxy-mode=secure` → warn, force `tls`
- Empty API link → fallback builder with correct prefix
- telemt failed start → existing journalctl / die path
