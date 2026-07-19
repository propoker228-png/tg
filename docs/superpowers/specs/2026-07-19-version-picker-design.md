# telemt-deploy: version picker and colored install summary

**Date:** 2026-07-19  
**Status:** Approved for implementation

## Goal

Before installation starts, the installer must:

1. Fetch the latest telemt release plus the three previous releases from GitHub and let the operator choose which version to install.
2. Let the operator choose MEKO mode (inline SYN FIX or full MEKO Launcher), then fetch the latest MEKO release plus three previous releases and let the operator choose which version to install.
3. Highlight all important install parameters with colored terminal output, including a final summary block before install begins.

This applies even when `--yes` is passed: version and MEKO selection remain interactive. `--yes` only skips redundant yes/no confirmations on destructive or secondary actions.

## Background

Current behavior (`lib/telemt.sh`, `lib/meko.sh`):

- telemt resolves to GitHub `latest` automatically; if newer than `TELEMT_BASELINE_VERSION` (`3.4.23`), a single yes/no prompt appears (skipped in `--yes` mode per the 2026-07-15 repair spec).
- MEKO inline is always the bundled template version (`MEKO_SYNFIX_VERSION=3.0.1`); MEKO full always pulls `install_main.sh` from `main`.
- Colors exist in `log_*` helpers but install prompts (domain, ad_tag, version) are mostly unstyled.

This design **supersedes** the 2026-07-15 rule that `--yes` may skip telemt version confirmation when latest exceeds baseline. Version choice is always interactive in the new prepare step.

## Scope

### In scope

- New modules: `lib/ui_highlight.sh`, `lib/version_picker.sh`
- New prepare step `prepare_install_options()` called after domain/DNS validation and before `run_install_flow()`
- GitHub release fetching for telemt and MEKO (4 versions each: latest + 3 previous)
- MEKO type selection: inline SYN FIX vs full MEKO Launcher (`mekopr`)
- MEKO install functions that download artifacts for a selected release tag
- Colored prompts and `print_install_summary()` before final install confirmation
- Move `prompt_ad_tag()` from post-install handoff into the prepare step (still optional; Enter skips)
- New CLI flag `--meko-version VER` to pre-highlight a version in the picker (picker still shown)
- Extend `tests/smoke.sh` with offline mocks for release parsing and summary rendering
- Update `README.md` / `INSTALL_INSTRUCTIONS.md` for new flow and flags

### Out of scope

- Version picker in menu item “Обновить telemt” (menu may reuse helpers later; not required in v1)
- Pinning MEKO inline scripts inside telemt-deploy repo (versions come from GitHub)
- Non-interactive install without TTY (cron/CI must fail with a clear message)
- Changing nginx, SSL, firewall, or verification logic beyond wiring selected versions

## User decisions (brainstorming)

| Question | Answer |
|----------|--------|
| `--yes` and version selection | Always show interactive picker (B) |
| MEKO modes in picker | Both inline and full; type first, then version (C) |
| Colored parameters | Domain, ad_tag, telemt, MEKO, SSL/:443, plus summary block (C) |

## Version sources

### telemt

- API: `https://api.github.com/repos/telemt/telemt/releases`
- Parse `tag_name`, strip leading `v`, validate with `is_valid_telemt_version`
- Sort semver descending; take top 4
- Mark index 0 as recommended (`★ latest`)
- Fallback on network/API failure: single option `TELEMT_BASELINE_VERSION` with `log_warn`

### MEKO (inline and full)

- API: `https://api.github.com/repos/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases`
- Parse `tag_name` (e.g. `v0.19` → `0.19`); validate tag format `^v?[0-9]+(\.[0-9]+)*$`
- Sort semver descending; take top 4 per picker invocation
- **Inline install at version `V`:** download from tag `V`:
  - `templates/apply-mtpr-synfix.sh` → `/opt/mtpr-simple/apply-mtpr-synfix.sh`
  - `mtpr-synfix-nft.sh` or bundled `templates/mtpr-synfix.service` if upstream layout differs (implementation may map paths; fallback to bundled service unit)
- **Full install at version `V`:** download `install_main.sh` at tag `V` and run non-interactively with pinned version env if supported; otherwise checkout tag via raw URL and run
- Fallback on network failure: inline uses bundled `templates/apply-mtpr-synfix.sh` (`MEKO_SYNFIX_VERSION`); full uses `main` with warning

Session state (no disk cache):

- `TELEMT_VERSION` — selected telemt version
- `MEKO_FULL` — `0` inline, `1` full (set from type picker)
- `MEKO_VERSION` — selected MEKO release tag (normalized, without `v` prefix in env; download uses `v` prefix as needed)

## Install prepare flow

Order inside `prepare_install_options()`:

```
1. Domain          — already set by prepare_install_domain(); re-display highlighted
2. pick_telemt_version()
3. pick_meko_type()        → sets MEKO_FULL
4. pick_meko_version()     → sets MEKO_VERSION
5. prompt_ad_tag()           — optional; moved before summary
6. print_install_summary()
7. confirm_action "Начать установку?"
```

### Flag behavior

| Flag | Effect |
|------|--------|
| `--domain` | Pre-filled; shown in summary |
| `--ad-tag` | Pre-filled; shown in summary |
| `--telemt-version` | Highlighted as “from flag” in telemt picker; user still chooses |
| `--meko-full` | Pre-selects “full” in type step; user still chooses |
| `--meko-version` | Highlighted in MEKO version picker; user still chooses |
| `--yes` | Does **not** skip steps 2–7; skips only redundant y/N on secondary confirms |

### TTY requirement

All picker steps read/write via `/dev/tty` (same as `prompt_*` and `dialog`). If TTY is unavailable:

```
die "Интерактивный выбор версий требует TTY. Запустите: sudo bash install.sh"
```

Even with `--yes`.

## UI / colors (`lib/ui_highlight.sh`)

Add to `lib/common.sh` color palette:

- `MAGENTA`, `GRAY` (in addition to existing `RED`, `GREEN`, `YELLOW`, `BLUE`, `CYAN`, `BOLD`, `NC`)

Helpers:

| Function | Renders |
|----------|---------|
| `hl_domain` | domain in `CYAN` + `BOLD` |
| `hl_telemt_version` | version in `GREEN` + `BOLD` |
| `hl_meko` | type + version in `YELLOW` + `BOLD` |
| `hl_adtag` | tag in `MAGENTA` or `GRAY` “не задан” |
| `hl_ssl` | `Let's Encrypt → :443` in `BLUE` |
| `print_install_summary` | bordered block with all fields |

Summary example:

```
══════════════════════════════════════
  Параметры установки
══════════════════════════════════════
  Домен:      example.com
  SSL:        Let's Encrypt → :443
  telemt:     3.4.24  ★ latest
  MEKO:       inline SYN FIX v3.0.1
  ad_tag:     не задан
══════════════════════════════════════
```

Picker UI:

- Prefer `dialog --menu` when `has_dialog && has_tty` (reuse `lib/dialog.sh`)
- Fallback: numbered list + `prompt_line` (consistent with `lib/menu.sh`)

## Architecture changes

### New files

- `lib/ui_highlight.sh` — `UI_HIGHLIGHT_SH_VERSION=1.0`
- `lib/version_picker.sh` — `VERSION_PICKER_SH_VERSION=1.0`

### Modified files

| File | Change |
|------|--------|
| `install.sh` | Source new modules; add `--meko-version`; call `prepare_install_options` |
| `lib/install_flow.sh` | Add `prepare_install_options()`; remove `prompt_ad_tag` from end of `run_install_flow` |
| `lib/telemt.sh` | `resolve_telemt_version` requires `TELEMT_VERSION` already set by picker (or die); remove auto-latest logic from install path |
| `lib/meko.sh` | `meko_install_inline_at`, `meko_install_full_at`; `meko_install` dispatches by `MEKO_VERSION` |
| `lib/handoff.sh` | `prompt_ad_tag` unchanged; called from prepare step instead |
| `lib/common.sh` | `MAGENTA`, `GRAY`; document that `is_auto_mode` does not bypass version picker |
| `tests/smoke.sh` | Mock release JSON tests, summary stdout test |
| `README.md`, `INSTALL_INSTRUCTIONS.md` | Document new flow |

### Data flow

```
install.sh
  └─ prepare_install_domain()
  └─ prepare_install_options()     # NEW
       ├─ pick_telemt_version()
       ├─ pick_meko_type()
       ├─ pick_meko_version()
       ├─ prompt_ad_tag()
       └─ print_install_summary() + confirm_action
  └─ run_install_flow()
       ├─ telemt_install()        # uses TELEMT_VERSION
       └─ meko_install()          # uses MEKO_FULL + MEKO_VERSION
```

## Error handling

| Condition | Behavior |
|-----------|----------|
| GitHub API unreachable | Fallback single version + `log_warn`; continue |
| Fewer than 4 releases | Show all available |
| Selected telemt binary 404 | `die` with message to pick another version |
| Selected MEKO artifact 404 | `die` with message to pick another version |
| No TTY | `die` with instruction to run interactively |
| Invalid release tag in API response | Skip tag during parse |

## Testing

Extend `tests/smoke.sh` (no network, no root):

- `fetch_telemt_releases_parse` — feed mock JSON file, assert 4 versions sorted
- `fetch_meko_releases_parse` — same for MEKO tags
- `print_install_summary_stdout` — summary renders without leaking prompt control chars
- `require_tty_for_picker` — document behavior (optional unit test with `has_tty` mocked if feasible)
- Existing `is_valid_telemt_version` tests remain

Run:

```bash
bash tests/smoke.sh
bash install.sh --help
```

## Implementation notes

- Reuse `jq` already required by telemt version fetch.
- GitHub API: set `User-Agent: telemt-deploy` header to avoid rate-limit issues.
- For MEKO full install at pinned tag, avoid piping `curl | bash` from `main` when a tagged `install_main.sh` exists.
- `save_state` should persist `TELEMT_VERSION`, `MEKO_VERSION`, and `MEKO_FULL` for status display.
- Menu path “Установка / переустановка” should call the same `prepare_install_options()` before `run_install_flow()` to avoid duplicated logic.

## Success criteria

- Operator sees 4 telemt versions and 4 MEKO versions (or fewer with warning) before install.
- Operator chooses MEKO type then MEKO version.
- Summary block shows domain, SSL, telemt, MEKO, ad_tag with distinct colors.
- `--yes` still shows pickers; install proceeds only after summary confirmation.
- `bash tests/smoke.sh` passes without network or system changes.
