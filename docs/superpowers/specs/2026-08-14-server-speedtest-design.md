# telemt-deploy: server internet speed test (menu item 15)

**Date:** 2026-08-14  
**Status:** Approved (brainstorming)

## Goal

Add an on-demand **server internet speed test** to telemt-deploy: download, upload, and ping/latency — similar to Speedtest.net. Available from main menu item **15** and CLI flag `--speedtest`, without requiring an installed proxy or domain.

## Background

Current diagnostics:

- Menu 9 — `doctor` / quick verify (DNS, SSL, services); requires domain for full flow
- `--meko-benchmark` — MEKO hashlimit only, not internet bandwidth
- Menu 13 — per-client egress shaping, not server channel measurement

No server-wide speed test exists today.

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| Purpose | **C** — manual on-demand test from menu |
| Metrics | **C** — download + upload + ping/latency (full report) |
| Method | **C** — hybrid: Ookla CLI first, curl/ping fallback |
| Menu placement | **B** — main menu item 15, always available (no domain required) |

## Approach

**Recommended: `lib/speedtest.sh` module with Ookla-first hybrid.**

Rejected:

- **curl-only** — cannot measure upload accurately without a dedicated endpoint
- **Embed in doctor** — not on-demand; doctor requires domain context

### Mode 1: Full (Ookla)

When official `speedtest` binary is available:

```text
Download:  842.3 Mbit/s
Upload:    615.1 Mbit/s
Ping:      12.4 ms
Jitter:    1.2 ms
Server:    Amsterdam, NL
ISP:       Example Provider
```

Invocation: `speedtest --accept-license --accept-gdpr --format=json` (non-interactive flags as required by Ookla CLI version).

Parse JSON fields: `download.bandwidth`, `upload.bandwidth`, `ping.latency`, `ping.jitter`, `server.name`, `server.location`, `isp`.

Ookla reports bandwidth in bytes/sec; convert to Mbit/s: `bytes_per_sec * 8 / 1_000_000`.

### Mode 2: Simplified fallback

When Ookla is unavailable or operator declines install:

| Metric | Method |
|--------|--------|
| Download | `curl` timed download from public test URLs |
| Ping | `ping -c 4` to 1.1.1.1 and 8.8.8.8 (show min/avg) |
| Upload | **Not measured** — display `н/д (требуется Ookla)` |

Do not fabricate upload numbers in fallback mode.

### Ookla installation (first run)

On first full-mode attempt, prompt (skipped with `--yes`):

1. Add Ookla apt repository and `apt install speedtest`, **or**
2. Download official static binary to `/usr/local/bin/speedtest`

Use whichever method matches existing `prereq.sh` / `ensure_packages` patterns. Installation is optional — declining falls back to simplified mode immediately.

## Fallback download details

Operator chooses test size in menu (default: quick):

| Profile | Size | Use case |
|---------|------|----------|
| Quick | ~10 MB | Fast check |
| Full | ~100 MB | More accurate |

**URL list** (try in order, 60s timeout each):

1. `https://speed.cloudflare.com/__down?bytes=25000000` (25 MB — quick profile uses 10M variant)
2. `https://proof.ovh.net/files/10Mb.dat`
3. `https://speed.hetzner.de/100MB.bin` (full profile only)

**Calculation:**

```text
Mbit/s = (bytes_downloaded × 8) / (elapsed_seconds × 1_000_000)
```

Use `curl -o /dev/null -w '%{time_total} %{size_download}' --max-time 60`.

## Architecture

### New files

| File | Responsibility |
|------|----------------|
| `lib/speedtest.sh` | Ookla detection/install, run, fallback, formatting |
| `tests/speedtest_smoke.sh` | Offline: Mbit/s math, JSON parse helpers |

### Key functions

| Function | Description |
|----------|-------------|
| `speedtest_has_ookla()` | Returns 0 if `speedtest` in PATH and executable |
| `speedtest_install_ookla()` | Installs Ookla CLI with operator confirm |
| `speedtest_run_ookla()` | Runs Ookla, prints formatted report |
| `speedtest_run_fallback_download(profile)` | curl-based download test |
| `speedtest_run_fallback_ping()` | ping to 1.1.1.1 / 8.8.8.8 |
| `speedtest_format_mbit(bytes, seconds)` | Prints Mbit/s with 1 decimal |
| `run_speedtest()` | Orchestrator: offer Ookla install → Ookla → fallback |
| `menu_speedtest()` | Menu wrapper with profile prompt |

### Integration

| File | Change |
|------|--------|
| `install.sh` | `--speedtest` flag, load `speedtest` module, `SPEEDTEST_SH_VERSION` bundle check, early-exit branch |
| `lib/menu.sh` | Item 15, case branch; **no** `require_installed()` |
| `README.md` | Document menu 15 and `--speedtest` |

### CLI

```bash
sudo bash install.sh --speedtest
sudo bash install.sh --speedtest --yes   # auto-accept Ookla install prompt
```

`--speedtest` bypasses interactive menu (like `--doctor`, `--status`).

## Menu UX (item 15)

```
=== Тест скорости интернета ===

  1) Быстрый тест (~10 MB)
  2) Полный тест (~100 MB)
  0) Назад
```

After selection, `run_speedtest` runs with chosen profile.

Display mode label:

- `Режим: Ookla Speedtest` or
- `Режим: упрощённый (curl/ping)`

Show traffic warning before test: «Тест использует интернет-трафик».

## Error handling

- No network / all URLs fail → `log_err` with last curl error, suggest checking firewall/routing
- Ookla install fails → log warn, proceed to fallback automatically
- `ping` unavailable → skip ping line, note in output
- Partial curl success → use first successful URL only

## Constraints

- IPv4 only (consistent with installer)
- Does not stop telemt/nginx services
- Does not require root beyond existing installer (`require_root` still applies)
- Does not run automatically in doctor (v1)

## Testing

### `tests/speedtest_smoke.sh` (offline)

- `speedtest_format_mbit` with known byte/time inputs
- Ookla JSON parse helper with fixture string (embedded sample JSON)
- Profile byte size selection logic

No live network calls in smoke tests.

### Manual checklist

1. Fresh VPS, menu 15 → fallback mode shows download + ping, upload = н/д
2. Accept Ookla install → full report with upload
3. `install.sh --speedtest --yes` from CLI works without menu
4. Menu 15 works before telemt is installed
5. Quick vs full profile changes download size

## Out of scope (v1)

- Automatic speed test in `doctor`
- IPv6 speed test
- Historical results / logging to file
- Speed test through MTProxy (client path)
- iperf3 (requires remote server)
- Integration with shaping verification (menu 13)

## Success criteria

- Operator can run a one-click speed test from menu 15 on any VPS
- Full mode reports download, upload, ping when Ookla is available
- Fallback mode honestly reports download + ping only
- No dependency on proxy installation or domain configuration
