# Obfuscated2 (secure/dd) Proxy Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add standalone install option for Obfuscated2 (`dd`) MTProxy mode alongside existing Fake TLS (`ee`) default, with full nginx + LE + MEKO stack unchanged.

**Architecture:** New `lib/proxy_mode.sh` owns `PROXY_MODE` (`tls`|`secure`), interactive picker (standalone only), and cluster guard. `telemt.toml.tpl` gets `${MODE_TLS}` / `${MODE_SECURE}` via existing `render_template()`. Link/API paths switch on `proxy_mode_link_kind()`.

**Tech Stack:** Bash 5.x, telemt TOML, telemt API `127.0.0.1:9091/v1/users`, envsubst templates, offline smoke tests.

## Global Constraints

- One mode per server: `tls` (Fake TLS / `ee`, default) or `secure` (Obfuscated2 / `dd`)
- Full stack for both modes: telemt:443 + nginx self-mask:8444 + Let's Encrypt + MEKO
- Cluster roles (`node`, `master_lb`, `lb`, `master`) always `tls`; `--proxy-mode=secure` → `log_warn` + force `tls`
- Standalone only for secure mode selection
- Old state without `PROXY_MODE` → `tls`
- In-place mode switch without `--fresh` not supported in v1
- Link secure: `tg://proxy?server=DOMAIN&port=443&secret=dd{32hex}` (no domain hex)
- Link tls: `secret=ee{32hex}{domain_hex}` (unchanged)
- Spec: `docs/superpowers/specs/2026-08-12-obfuscated2-proxy-mode-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/proxy_mode.sh` | Create | Mode constants, normalize, picker, cluster guard |
| `tests/proxy_mode_smoke.sh` | Create | Offline tests for mode helpers, template, links |
| `templates/telemt.toml.tpl` | Modify | `${MODE_TLS}`, `${MODE_SECURE}` |
| `lib/common.sh` | Modify | `render_template`, `fetch_proxy_link`, `save_state` |
| `lib/link.sh` | Modify | Mode-aware `build_proxy_link_fallback` |
| `lib/env.sh` | Modify | Load `PROXY_MODE` from state |
| `lib/telemt.sh` | Modify | Export mode vars in `telemt_write_config` |
| `lib/version_picker.sh` | Modify | `pick_proxy_mode()` in `prepare_install_options` |
| `lib/ui_highlight.sh` | Modify | Summary line for mode |
| `lib/role_wizard.sh` | Modify | Standalone summary line |
| `install.sh` | Modify | `--proxy-mode`, module load, validate |
| `tests/smoke.sh` | Modify | Syntax + invoke `proxy_mode_smoke.sh` |
| `README.md` | Modify | Flag + mode docs |
| `DEPLOY.md` | Modify | Secure install example |

**Out of scope:** `lib/cluster.sh`, `lib/panel_api.py`, `lib/haproxy.sh`

---

### Task 1: `lib/proxy_mode.sh` + smoke tests

**Files:**
- Create: `lib/proxy_mode.sh`
- Create: `tests/proxy_mode_smoke.sh`
- Modify: `tests/smoke.sh`

**Interfaces:**
- Produces: `PROXY_MODE_SH_VERSION="1.0"`
- Produces: `normalize_proxy_mode(mode) -> sets PROXY_MODE or dies`
- Produces: `proxy_mode_is_secure() -> exit 0 if PROXY_MODE=secure`
- Produces: `proxy_mode_label() -> prints "Fake TLS (ee)" or "Obfuscated2 (dd)"`
- Produces: `proxy_mode_link_kind() -> prints "tls" or "secure"`
- Produces: `proxy_mode_default() -> sets PROXY_MODE=tls`
- Produces: `proxy_mode_force_tls_for_cluster() -> if cluster role != standalone, warn and set tls`

- [ ] **Step 1: Create failing smoke tests**

Create `tests/proxy_mode_smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export DEPLOY_ROOT="$ROOT"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/proxy_mode.sh
source "$ROOT/lib/proxy_mode.sh"

proxy_mode_default
[ "$PROXY_MODE" = "tls" ] && pass "default tls" || fail "default tls got=$PROXY_MODE"

PROXY_MODE=tls
normalize_proxy_mode "secure"
[ "$PROXY_MODE" = "secure" ] && pass "normalize secure" || fail "normalize secure"

PROXY_MODE=tls
normalize_proxy_mode "TLS"
[ "$PROXY_MODE" = "tls" ] && pass "normalize TLS case" || fail "normalize TLS case"

if PROXY_MODE=tls normalize_proxy_mode "bogus" 2>/dev/null; then
  fail "reject bogus mode"
else
  pass "reject bogus mode"
fi

PROXY_MODE=secure
[ "$(proxy_mode_link_kind)" = "secure" ] && pass "link kind secure" || fail "link kind secure"
PROXY_MODE=tls
[ "$(proxy_mode_link_kind)" = "tls" ] && pass "link kind tls" || fail "link kind tls"

PROXY_MODE=secure
[[ "$(proxy_mode_label)" == *"dd"* ]] && pass "label secure" || fail "label secure"
PROXY_MODE=tls
[[ "$(proxy_mode_label)" == *"ee"* ]] && pass "label tls" || fail "label tls"

CLUSTER_ROLE=node
PROXY_MODE=secure
proxy_mode_force_tls_for_cluster
[ "$PROXY_MODE" = "tls" ] && pass "cluster forces tls" || fail "cluster forces tls"

exit "$FAIL"
```

Add to `tests/smoke.sh` (after other module syntax checks):

```bash
check_syntax "$ROOT/lib/proxy_mode.sh"
bash "$ROOT/tests/proxy_mode_smoke.sh" || FAIL=1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/proxy_mode_smoke.sh`
Expected: FAIL (no such file or functions not found)

- [ ] **Step 3: Implement `lib/proxy_mode.sh`**

Create `lib/proxy_mode.sh`:

```bash
#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROXY_MODE_SH_VERSION="1.0"
PROXY_MODE="${PROXY_MODE:-tls}"

proxy_mode_default() {
  PROXY_MODE=tls
  export PROXY_MODE
}

normalize_proxy_mode() {
  local raw="${1:-}"
  raw="$(trim_whitespace "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    tls|fake-tls|ee|"") PROXY_MODE=tls ;;
    secure|obfuscated2|dd) PROXY_MODE=secure ;;
    *) die "Неизвестный режим прокси: $raw (допустимо: tls, secure)" ;;
  esac
  export PROXY_MODE
}

proxy_mode_is_secure() {
  [ "${PROXY_MODE:-tls}" = "secure" ]
}

proxy_mode_label() {
  if proxy_mode_is_secure; then
    echo "Obfuscated2 (dd)"
  else
    echo "Fake TLS (ee)"
  fi
}

proxy_mode_link_kind() {
  if proxy_mode_is_secure; then
    echo "secure"
  else
    echo "tls"
  fi
}

proxy_mode_is_standalone_context() {
  local role="${SELECTED_INSTALL_ROLE:-${CLUSTER_ROLE:-standalone}}"
  [ "$role" = "standalone" ]
}

proxy_mode_force_tls_for_cluster() {
  local role="${CLUSTER_ROLE:-standalone}"
  case "$role" in
    standalone) return 0 ;;
  esac
  if [ "${PROXY_MODE:-tls}" = "secure" ]; then
    log_warn "Режим secure (dd) только для standalone — используем Fake TLS (ee)"
    PROXY_MODE=tls
    export PROXY_MODE
  fi
}

pick_proxy_mode() {
  proxy_mode_default
  proxy_mode_force_tls_for_cluster
  proxy_mode_is_standalone_context || return 0
  [ -n "${PROXY_MODE:-}" ] && [ "${PROXY_MODE}" != "tls" ] && return 0
  if is_auto_mode && [ -n "${PROXY_MODE_CLI:-}" ]; then
    normalize_proxy_mode "$PROXY_MODE_CLI"
    return 0
  fi
  is_auto_mode && return 0
  has_tty || die "Выбор режима прокси требует TTY. Запустите: sudo bash install.sh"
  local choice=""
  while true; do
    echo ""
    echo -e "${BOLD}=== Режим прокси ===${NC}"
    echo "  1) Fake TLS (ee) — рекомендуется, маскировка под HTTPS"
    echo "  2) Obfuscated2 (dd) — random padding, без Fake TLS"
    prompt_line choice "Выбор [1/2]" "1"
    case "$choice" in
      1|""|tls|ee) PROXY_MODE=tls; break ;;
      2|secure|dd) PROXY_MODE=secure; break ;;
      *) log_warn "Введите 1 или 2" ;;
    esac
  done
  export PROXY_MODE
  log_ok "Режим: $(proxy_mode_label)"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/proxy_mode_smoke.sh`
Expected: all OK

- [ ] **Step 5: Commit**

```bash
git add lib/proxy_mode.sh tests/proxy_mode_smoke.sh tests/smoke.sh
git commit -m "feat(proxy-mode): add mode helpers and offline smoke tests"
```

---

### Task 2: telemt.toml template + render_template

**Files:**
- Modify: `templates/telemt.toml.tpl`
- Modify: `lib/common.sh`
- Modify: `tests/proxy_mode_smoke.sh`

**Interfaces:**
- Consumes: `proxy_mode_is_secure()`, `PROXY_MODE` from Task 1
- Produces: `render_template()` sets `MODE_TLS`, `MODE_SECURE`, `TLS_EMULATION` before envsubst
- Produces: rendered `/etc/telemt/telemt.toml` with correct modes

- [ ] **Step 1: Add template render tests to smoke**

Append to `tests/proxy_mode_smoke.sh`:

```bash
render_telemt_tpl() {
  local mode="$1"
  PROXY_MODE="$mode"
  export PROXY_MODE DOMAIN=example.com TLS_DOMAIN=mask.example.com SECRET=0123456789abcdef0123456789abcdef AD_TAG_LINE=""
  export PUBLIC_HOST="$DOMAIN" TELEMT_TLS_DOMAIN="$TLS_DOMAIN"
  if [ "$mode" = "secure" ]; then
    export MODE_TLS=false MODE_SECURE=true TLS_EMULATION=false
  else
    export MODE_TLS=true MODE_SECURE=false TLS_EMULATION=false
  fi
  envsubst '${MODE_TLS} ${MODE_SECURE} ${PUBLIC_HOST} ${TELEMT_TLS_DOMAIN} ${TLS_EMULATION} ${SECRET} ${AD_TAG_LINE}' \
    < "$ROOT/templates/telemt.toml.tpl"
}

out=$(render_telemt_tpl secure)
echo "$out" | grep -q 'secure = true' && pass "tpl secure true" || fail "tpl secure true"
echo "$out" | grep -q 'tls = false' && pass "tpl tls false secure" || fail "tpl tls false secure"
echo "$out" | grep -q 'tls_emulation = false' && pass "tpl no emulation secure" || fail "tpl no emulation secure"

out=$(render_telemt_tpl tls)
echo "$out" | grep -q 'tls = true' && pass "tpl tls true" || fail "tpl tls true"
echo "$out" | grep -q 'secure = false' && pass "tpl secure false tls" || fail "tpl secure false tls"
```

- [ ] **Step 2: Run tests — expect FAIL on template lines**

Run: `bash tests/proxy_mode_smoke.sh`
Expected: FAIL on `tpl secure true` (template still hardcoded)

- [ ] **Step 3: Update `templates/telemt.toml.tpl`**

Replace `[general.modes]` block:

```toml
[general.modes]
classic = false
secure = ${MODE_SECURE}
tls = ${MODE_TLS}
```

(`tls_emulation = ${TLS_EMULATION}` already present in `[censorship]`)

- [ ] **Step 4: Update `render_template()` in `lib/common.sh`**

Inside `render_template()`, before `export DOMAIN TLS_DOMAIN...`:

```bash
  if proxy_mode_is_secure 2>/dev/null; then
    MODE_TLS=false
    MODE_SECURE=true
    TLS_EMULATION=false
  else
    MODE_TLS=true
    MODE_SECURE=false
    if install_is_ip_only; then
      TLS_EMULATION=true
    elif [ "${TLS_DOMAIN:-}" != "${DOMAIN:-}" ]; then
      TLS_EMULATION=true
    else
      TLS_EMULATION=false
    fi
  fi
  export MODE_TLS MODE_SECURE
```

Remove duplicate TLS_EMULATION if/elif block that follows (now integrated above).

Add `${MODE_TLS} ${MODE_SECURE}` to both envsubst lines.

Note: `proxy_mode.sh` must load before `common.sh` uses `proxy_mode_is_secure` — add `proxy_mode` to install.sh module list **before** modules that call `render_template`, or source proxy_mode from common.sh. **Decision:** add `proxy_mode` immediately after `common` in `install.sh` for loop (Task 4).

For smoke tests, source order is already common then proxy_mode — move `proxy_mode_is_secure` call to after sourcing both, or duplicate minimal check in test. Tests source both; add early in `common.sh`:

```bash
proxy_mode_is_secure() {
  if declare -f proxy_mode_is_secure_impl >/dev/null 2>&1; then
    proxy_mode_is_secure_impl
  else
    [ "${PROXY_MODE:-tls}" = "secure" ]
  fi
}
```

Simpler approach: in `proxy_mode.sh` rename to no conflict — keep `proxy_mode_is_secure` only in proxy_mode.sh; in `render_template` use `[ "${PROXY_MODE:-tls}" = "secure" ]` inline to avoid circular source. Use inline check in `render_template`:

```bash
  if [ "${PROXY_MODE:-tls}" = "secure" ]; then
```

- [ ] **Step 5: Run tests**

Run: `bash tests/proxy_mode_smoke.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add templates/telemt.toml.tpl lib/common.sh tests/proxy_mode_smoke.sh
git commit -m "feat(proxy-mode): parameterize telemt.toml modes for secure/dd"
```

---

### Task 3: Link generation + API fetch + state

**Files:**
- Modify: `lib/common.sh` (`fetch_proxy_link`, `save_state`)
- Modify: `lib/link.sh`
- Modify: `lib/env.sh`
- Modify: `lib/telemt.sh`
- Modify: `tests/proxy_mode_smoke.sh`

**Interfaces:**
- Consumes: `proxy_mode_link_kind()`, `PROXY_MODE`
- Produces: `fetch_proxy_link()` reads `links.{tls|secure}[0]`
- Produces: `build_proxy_link_fallback()` dd vs ee format
- Produces: `save_state` writes `PROXY_MODE=...`
- Produces: `env_load_settings` exports `PROXY_MODE`

- [ ] **Step 1: Add link tests to smoke**

```bash
export DOMAIN=example.com SECRET=0123456789abcdef0123456789abcdef TLS_DOMAIN=mask.example.com
PROXY_MODE=secure
out=$(build_proxy_link_fallback)
[[ "$out" == *"secret=dd0123456789abcdef0123456789abcdef" ]] && pass "fallback dd" || fail "fallback dd got=$out"
[[ "$out" != *"mask.example"* ]] && pass "fallback dd no domain hex" || fail "fallback dd no domain hex"

PROXY_MODE=tls
out=$(build_proxy_link_fallback)
[[ "$out" == tg://proxy?server=example.com* ]] && pass "fallback tls prefix" || fail "fallback tls"
[[ "$out" == *"secret=ee"* ]] && pass "fallback ee" || fail "fallback ee"
```

Source `link.sh` in smoke after env mock (may need `env_load_settings` stub — set vars directly before call).

- [ ] **Step 2: Run — expect FAIL**

Run: `bash tests/proxy_mode_smoke.sh`

- [ ] **Step 3: Update `fetch_proxy_link()` in `lib/common.sh`**

Replace hardcoded `tls` key:

```bash
fetch_proxy_link() {
  local kind
  kind="$(proxy_mode_link_kind 2>/dev/null || echo tls)"
  curl -fsS http://127.0.0.1:9091/v1/users 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['data'][0]['links']; k=sys.argv[1]; print(d[k][0] if k in d and d[k] else '')" "$kind" 2>/dev/null
}
```

- [ ] **Step 4: Update `lib/link.sh` `build_proxy_link_fallback()`**

After loading domain/secret, resolve mode:

```bash
  env_load_settings 2>/dev/null || true
  PROXY_MODE="${PROXY_MODE:-tls}"
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  if proxy_mode_is_secure; then
    printf 'tg://proxy?server=%s&port=443&secret=dd%s' "$domain" "$secret"
    return 0
  fi
  # existing ee path...
```

- [ ] **Step 5: Update `save_state()` in `lib/common.sh`**

Add line to heredoc:

```
PROXY_MODE=${PROXY_MODE:-tls}
```

- [ ] **Step 6: Update `env_load_settings()` in `lib/env.sh`**

In state source block, add `PROXY_MODE` to export list:

```bash
    export DOMAIN SECRET AD_TAG TLS_DOMAIN INSTALL_IP_ONLY PROXY_MODE
```

After source, default:

```bash
  PROXY_MODE="${PROXY_MODE:-tls}"
  export PROXY_MODE
```

- [ ] **Step 7: Update `telemt_write_config()` in `lib/telemt.sh`**

At start of function:

```bash
  PROXY_MODE="${PROXY_MODE:-tls}"
  export PROXY_MODE
```

(no other changes — render_template reads PROXY_MODE)

- [ ] **Step 8: Run tests**

Run: `bash tests/proxy_mode_smoke.sh`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/common.sh lib/link.sh lib/env.sh lib/telemt.sh tests/proxy_mode_smoke.sh
git commit -m "feat(proxy-mode): mode-aware links, API fetch, and state"
```

---

### Task 4: Install CLI + wizard integration

**Files:**
- Modify: `install.sh`
- Modify: `lib/version_picker.sh`
- Modify: `lib/ui_highlight.sh`
- Modify: `lib/role_wizard.sh`

**Interfaces:**
- Consumes: `pick_proxy_mode()`, `normalize_proxy_mode()`, `proxy_mode_force_tls_for_cluster()`
- Produces: `--proxy-mode` CLI flag, `PROXY_MODE_CLI` for auto mode

- [ ] **Step 1: Add `proxy_mode` to install.sh module list**

In `for mod in ...` line, insert `proxy_mode` immediately after `common` is sourced separately — add as first module in loop:

```bash
for mod in proxy_mode prereq dns nginx ...
```

- [ ] **Step 2: Parse `--proxy-mode` in install.sh**

Add variable:

```bash
PROXY_MODE="tls"; PROXY_MODE_CLI=""
```

In arg loop:

```bash
    --proxy-mode) PROXY_MODE_CLI=$(require_arg_value "$1" "${2:-}"); normalize_proxy_mode "$PROXY_MODE_CLI"; shift 2 ;;
```

Export after cluster role case:

```bash
proxy_mode_force_tls_for_cluster
export PROXY_MODE
```

Add to help text:

```
#   --proxy-mode MODE       tls (Fake TLS, default) | secure (Obfuscated2/dd); standalone only
```

- [ ] **Step 3: Call `pick_proxy_mode` in `prepare_install_options()`**

In `lib/version_picker.sh`, at start of `prepare_install_options()` after `require_tty_for_picker`:

```bash
  pick_proxy_mode
```

- [ ] **Step 4: Add summary lines**

In `lib/ui_highlight.sh` `print_install_summary()`, after domain block:

```bash
  echo -e "  Режим:      $(proxy_mode_label)"
```

In `lib/role_wizard.sh` `print_role_summary()` standalone case, after domain line:

```bash
      echo -e "  Режим:     ${CYAN}$(proxy_mode_label)${NC}"
```

- [ ] **Step 5: Syntax check**

Run: `bash -n install.sh; bash tests/smoke.sh`
Expected: PASS (proxy_mode smoke included)

- [ ] **Step 6: Commit**

```bash
git add install.sh lib/version_picker.sh lib/ui_highlight.sh lib/role_wizard.sh
git commit -m "feat(proxy-mode): CLI flag and install wizard integration"
```

---

### Task 5: Documentation + full smoke

**Files:**
- Modify: `README.md`
- Modify: `DEPLOY.md`
- Modify: `docs/superpowers/specs/2026-08-12-obfuscated2-proxy-mode-design.md` (Status → Implemented after done)

- [ ] **Step 1: README.md**

Add to flags table:

| `--proxy-mode MODE` | `tls` (Fake TLS, default) или `secure` (Obfuscated2/dd); только standalone |

Add subsection under examples:

```bash
sudo bash install.sh --domain example.com --proxy-mode=secure --yes
```

Note: cluster roles ignore secure mode.

- [ ] **Step 2: DEPLOY.md**

Add short section «Obfuscated2 (dd)» with same example and note that nginx/MEKO still install.

- [ ] **Step 3: Run full offline tests**

Run: `bash tests/smoke.sh`
Expected: all OK

- [ ] **Step 4: Commit**

```bash
git add README.md DEPLOY.md docs/superpowers/specs/2026-08-12-obfuscated2-proxy-mode-design.md
git commit -m "docs: document Obfuscated2 secure proxy mode"
```

---

### Task 6: Push to GitHub

- [ ] **Step 1: Push branch**

```bash
git push origin main
```

Requires git user configured and remote access to `propoker228-png/tg`.

---

## Manual verification (Ubuntu server)

1. `sudo bash install.sh --domain DOMAIN --proxy-mode=secure --yes`
2. `sudo tg link` → secret starts with `dd`
3. Connect Telegram client
4. `sudo tg doctor --quick` → pass
5. Default install without flag → `ee` link (regression)

---

## Plan self-review

| Spec requirement | Task |
|------------------|------|
| Mode A (one per server) | Task 1, 4 |
| Full stack A1 | No nginx changes; Task 2 template |
| Standalone B1 | Task 1 cluster guard, Task 4 |
| `--proxy-mode` CLI | Task 4 |
| `PROXY_MODE` state | Task 3 |
| telemt.toml modes | Task 2 |
| Link dd format | Task 3 |
| fetch_proxy_link secure key | Task 3 |
| Smoke tests | Task 1–3, 5 |
| README/DEPLOY | Task 5 |
| Cluster unchanged | Out of scope |
| No in-place mode switch | Documented in spec only |

No placeholders remain. Type names consistent across tasks.
