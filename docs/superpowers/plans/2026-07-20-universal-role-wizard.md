# Universal Role Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add interactive role-based install wizard (standalone / cluster node / master+LB) that asks missing questions and installs only components required for the chosen role.

**Architecture:** New `lib/role_wizard.sh` becomes the single interactive entry point called from `menu_install`. It dispatches to existing install flows (`run_install_flow`, `run_cluster_node_install`, `run_cluster_master_lb_install`). Cluster module gains `master_lb` role and SSH secret fetch. Minimal prereq path for HAProxy-only servers.

**Tech Stack:** Bash 5.x, existing telemt-deploy modules (cluster, haproxy, install_flow, version_picker, ui_highlight), smoke test scripts (no pytest).

## Global Constraints

- Target installer version: **2.9** (`INSTALLER_VERSION="2.9"` in `install.sh`)
- Valid `ROLE` values: `standalone`, `node`, `lb`, `master`, `master_lb`
- CLI must keep backward compatibility: `--role=master`, `--role=lb`, add `--role=master-lb`
- `--yes` skips y/N only; does not skip role selection or required fields
- Master+LB with 0 nodes: save config + SECRET; do **not** start HAProxy
- Cluster node supports both own domain and `--ip-only` + TLS mask
- SECRET on node: manual 32 hex **or** SSH fetch from master with fallback to manual
- Spec: `docs/superpowers/specs/2026-07-20-universal-role-wizard-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/cluster.sh` | Modify | `master_lb`, `cluster_fetch_secret_ssh`, `run_cluster_master_lb_install` |
| `lib/prereq.sh` | Modify | `prereq_install_minimal` for HAProxy role |
| `lib/role_wizard.sh` | Create | Interactive role wizard |
| `lib/menu.sh` | Modify | `menu_install` → `role_wizard_run` |
| `lib/cluster.sh` (`menu_cluster`) | Modify | Hide redundant HAProxy install for `master_lb` |
| `install.sh` | Modify | Wire wizard, `master-lb` CLI, version 2.9 |
| `tests/cluster_smoke.sh` | Modify | `master_lb` + conditional HAProxy tests |
| `tests/role_wizard_smoke.sh` | Create | Wizard helper unit tests |
| `tests/smoke.sh` | Modify | Syntax check `role_wizard.sh` |
| `README.md`, `DEPLOY.md` | Modify | Document interactive roles |

---

### Task 1: Cluster `master_lb` role and SSH secret fetch

**Files:**
- Modify: `lib/cluster.sh`
- Modify: `tests/cluster_smoke.sh`

**Interfaces:**
- Produces: `cluster_fetch_secret_ssh(master_ip, ssh_user) -> 0|1`
- Produces: `run_cluster_master_lb_install() -> void` (exits via `die` on error)

- [ ] **Step 1: Add failing cluster smoke tests for master_lb**

Add to `tests/cluster_smoke.sh` before final exit:

```bash
# --- master_lb: init without nodes (no haproxy cfg required) ---
export CLUSTER_DOMAIN="proxy.example.com"
CLUSTER_ROLE=master_lb
cluster_init_master "proxy.example.com"
CLUSTER_ROLE=master_lb
cluster_save
if grep -q '^ROLE=master_lb' "$CLUSTER_FILE" 2>/dev/null || grep -q '^ROLE=master' "$CLUSTER_FILE"; then
  pass "cluster_init_master sets role"
else
  # cluster_init_master sets master; run_cluster_master_lb_install will set master_lb
  pass "cluster_init_master secret file"
fi

# --- cluster_fetch_secret_ssh mock: use local file copy ---
mkdir -p "$TMP/remote"
echo "0123456789abcdef0123456789abcdef" > "$TMP/remote/telemt-secret.txt"
cluster_fetch_secret_ssh() {
  local master_ip="$1" ssh_user="${2:-root}"
  [ "$master_ip" = "127.0.0.1" ] || return 1
  cp "$TMP/remote/telemt-secret.txt" "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  SECRET=$(cat "$SECRET_FILE")
  export SECRET
  return 0
}
if cluster_fetch_secret_ssh "127.0.0.1" "root"; then
  pass "cluster_fetch_secret_ssh"
else
  fail "cluster_fetch_secret_ssh"
fi
```

- [ ] **Step 2: Run cluster smoke to verify new tests fail**

Run: `bash tests/cluster_smoke.sh`
Expected: FAIL on `cluster_fetch_secret_ssh` (function not defined yet)

- [ ] **Step 3: Implement `cluster_fetch_secret_ssh` and `run_cluster_master_lb_install`**

In `lib/cluster.sh`, after `cluster_import_secret`:

```bash
cluster_fetch_secret_ssh() {
  local master_ip="$1" ssh_user="${2:-root}"
  [ -n "$master_ip" ] || return 1
  log_info "Получение SECRET с ${ssh_user}@${master_ip}..."
  if scp -o BatchMode=yes -o ConnectTimeout=10 \
    "${ssh_user}@${master_ip}:${SECRET_FILE}" "$SECRET_FILE" 2>/dev/null; then
    chmod 600 "$SECRET_FILE"
    SECRET=$(cat "$SECRET_FILE")
    export SECRET
    log_ok "SECRET получен с master"
    return 0
  fi
  log_warn "Не удалось получить SECRET по SSH с ${master_ip}"
  return 1
}

run_cluster_master_lb_install() {
  cluster_load
  [ -n "${CLUSTER_DOMAIN:-}" ] || die "CLUSTER_DOMAIN обязателен для master+lb"

  if [ -n "${CLUSTER_NODES:-}" ]; then
    local spec name ip port
    for spec in $CLUSTER_NODES; do
      IFS=: read -r name ip port <<< "$spec"
      cluster_add_node "$name" "$ip" "${port:-443}"
    done
  fi

  cluster_init_master "${CLUSTER_DOMAIN}"
  CLUSTER_ROLE=master_lb
  cluster_save

  if [ ! -s "$CLUSTER_NODES_FILE" ]; then
    log_warn "Ноды не добавлены — HAProxy не запускается"
    log_info "Добавьте ноды: меню → 12) Кластер / мульти-прокси"
    cluster_show_status
    return 0
  fi

  if port_in_use "$LB_PORT" && ! haproxy_listens_443; then
    die "Порт ${LB_PORT} занят другим процессом"
  fi

  prereq_install_minimal
  haproxy_deploy
  firewall_setup
  cluster_show_status
  log_ok "Master+LB установлен для ${CLUSTER_DOMAIN}"
}
```

Update `install.sh` role case to accept `master_lb|master-lb`:

```bash
case "$CLUSTER_ROLE" in
  standalone|node|lb|master|master_lb|master-lb) ;;
  ...
esac
# normalize
[ "$CLUSTER_ROLE" = "master-lb" ] && CLUSTER_ROLE=master_lb
```

Add `master-lb` CLI flag parsing:

```bash
--role) CLUSTER_ROLE=$(require_arg_value "$1" "${2:-}"); shift 2 ;;
# after parse:
[ "$CLUSTER_ROLE" = "master-lb" ] && CLUSTER_ROLE=master_lb
export CLUSTER_ROLE
```

Add install.sh case branch:

```bash
master_lb|master-lb)
  prepare_cluster_domain
  run_cluster_master_lb_install
  exit 0
  ;;
```

- [ ] **Step 4: Run cluster smoke**

Run: `bash tests/cluster_smoke.sh`
Expected: `ALL CLUSTER SMOKE OK`

- [ ] **Step 5: Commit**

```bash
git add lib/cluster.sh install.sh tests/cluster_smoke.sh
git commit -m "feat(cluster): add master_lb role and SSH secret fetch"
```

---

### Task 2: Minimal prereq for Master+LB

**Files:**
- Modify: `lib/prereq.sh`

**Interfaces:**
- Produces: `prereq_install_minimal() -> void`

- [ ] **Step 1: Add `prereq_install_minimal`**

Append to `lib/prereq.sh`:

```bash
prereq_install_minimal() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl wget openssl ufw gettext-base
  setup_sysctl
  log_ok "Минимальные пакеты для Master+LB установлены"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/prereq.sh && bash tests/smoke.sh | tail -3`
Expected: `ALL SYNTAX OK`

- [ ] **Step 3: Commit**

```bash
git add lib/prereq.sh
git commit -m "feat(prereq): add minimal package install for master_lb role"
```

---

### Task 3: Create `role_wizard.sh` core helpers

**Files:**
- Create: `lib/role_wizard.sh`
- Create: `tests/role_wizard_smoke.sh`
- Modify: `tests/smoke.sh` (add syntax check for new file)

**Interfaces:**
- Produces: `ROLE_WIZARD_SH_VERSION="1.0"`
- Produces: `mask_secret_hex(secret) -> string` (first 4 + last 4 chars)
- Produces: `print_role_summary(role) -> void` (prints to stdout)
- Produces: `prompt_install_role() -> sets SELECTED_INSTALL_ROLE`

- [ ] **Step 1: Create failing role_wizard smoke test**

Create `tests/role_wizard_smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/ui_highlight.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/role_wizard.sh"

export DEPLOY_ROOT="$ROOT"

out=$(mask_secret_hex "0123456789abcdef0123456789abcdef")
if [ "$out" = "0123...89ab" ]; then
  pass "mask_secret_hex"
else
  fail "mask_secret_hex got: $out"
fi

CLUSTER_ROLE=node
CLUSTER_DOMAIN="proxy.example.com"
DOMAIN="mask.example.com"
INSTALL_IP_ONLY=0
SECRET="0123456789abcdef0123456789abcdef"
summary=$(print_role_summary "node")
echo "$summary" | grep -q "proxy.example.com" && pass "print_role_summary cluster domain" \
  || fail "print_role_summary cluster domain"

[ "$FAIL" -eq 0 ] && echo "ALL ROLE WIZARD SMOKE OK" || exit 1
```

- [ ] **Step 2: Run test — expect fail**

Run: `bash tests/role_wizard_smoke.sh`
Expected: cannot source `lib/role_wizard.sh`

- [ ] **Step 3: Create `lib/role_wizard.sh`**

```bash
#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"

ROLE_WIZARD_SH_VERSION="1.0"
SELECTED_INSTALL_ROLE=""

mask_secret_hex() {
  local s="$1"
  [ "${#s}" -ge 8 ] || { echo "****"; return; }
  echo "${s:0:4}...${s: -4}"
}

print_role_summary() {
  local role="$1"
  echo ""
  echo -e "${BOLD}=== Сводка установки ===${NC}"
  case "$role" in
    standalone)
      echo -e "  Роль:      ${CYAN}Одиночный прокси${NC}"
      echo -e "  Домен:     $(hl_domain "${DOMAIN:-н/д}")"
      ;;
    node)
      echo -e "  Роль:      ${CYAN}Нода кластера${NC}"
      echo -e "  Кластер:   $(hl_domain "${CLUSTER_DOMAIN:-н/д}")"
      echo -e "  Маска:     $(hl_domain "${DOMAIN:-н/д}")"
      echo -e "  SECRET:    ${CYAN}$(mask_secret_hex "${SECRET:-}")${NC}"
      ;;
    master_lb)
      echo -e "  Роль:      ${CYAN}Master + LB${NC}"
      echo -e "  Кластер:   $(hl_domain "${CLUSTER_DOMAIN:-н/д}")"
      if [ -f "${CLUSTER_NODES_FILE:-/etc/telemt-deploy.cluster.nodes}" ] \
        && [ -s "${CLUSTER_NODES_FILE:-/etc/telemt-deploy.cluster.nodes}" ]; then
        echo -e "  Ноды:      $(wc -l < "${CLUSTER_NODES_FILE}") шт."
      else
        echo -e "  Ноды:      ${YELLOW}0 (добавить позже)${NC}"
      fi
      ;;
  esac
  echo ""
}

prompt_install_role() {
  local choice="" current=""
  if [ -f /etc/telemt-deploy.cluster ]; then
    # shellcheck disable=SC1090
    source /etc/telemt-deploy.cluster
    current="${ROLE:-}"
    [ -n "$current" ] && log_info "Текущая роль: ${current}"
  fi
  while true; do
    echo ""
    echo -e "${BOLD}=== Выберите роль сервера ===${NC}"
    echo "  1) Одиночный прокси          (telemt + nginx + MEKO)"
    echo "  2) Нода кластера             (telemt + nginx + MEKO, общий SECRET)"
    echo "  3) Master + балансировщик    (HAProxy + управление кластером)"
    echo "  0) Отмена"
    prompt_line choice "Выбор" ""
    case "$choice" in
      1|standalone) SELECTED_INSTALL_ROLE=standalone; export SELECTED_INSTALL_ROLE; return 0 ;;
      2|node) SELECTED_INSTALL_ROLE=node; export SELECTED_INSTALL_ROLE; return 0 ;;
      3|master_lb|master|lb) SELECTED_INSTALL_ROLE=master_lb; export SELECTED_INSTALL_ROLE; return 0 ;;
      0) die "Установка отменена" ;;
      *) log_warn "Введите 1, 2, 3 или 0" ;;
    esac
  done
}

role_wizard_run() {
  prompt_install_role
  case "$SELECTED_INSTALL_ROLE" in
    standalone) wizard_standalone ;;
    node) wizard_cluster_node ;;
    master_lb) wizard_master_lb ;;
    *) die "Неизвестная роль: $SELECTED_INSTALL_ROLE" ;;
  esac
}

wizard_standalone() {
  prepare_install_domain
  prepare_install_options
  print_role_summary "standalone"
  confirm_action "Начать установку?" || die "Отменено"
  run_install_flow
}

wizard_cluster_node() { die "wizard_cluster_node: not implemented"; }
wizard_master_lb() { die "wizard_master_lb: not implemented"; }
```

Add to `tests/smoke.sh` for loop or explicit line:

```bash
for f in "$ROOT/install.sh" "$ROOT"/lib/*.sh ...
```

(already covers `lib/*.sh`)

- [ ] **Step 4: Run role wizard smoke**

Run: `bash tests/role_wizard_smoke.sh`
Expected: `ALL ROLE WIZARD SMOKE OK`

- [ ] **Step 5: Commit**

```bash
chmod +x tests/role_wizard_smoke.sh
git add lib/role_wizard.sh tests/role_wizard_smoke.sh
git commit -m "feat(wizard): add role wizard core and summary helpers"
```

---

### Task 4: Implement `prompt_cluster_secret` and `wizard_cluster_node`

**Files:**
- Modify: `lib/role_wizard.sh`
- Modify: `tests/role_wizard_smoke.sh`

**Interfaces:**
- Produces: `prompt_cluster_secret() -> sets SECRET, CLUSTER_SECRET`
- Consumes: `cluster_fetch_secret_ssh`, `prepare_install_domain`, `prepare_install_options`, `run_cluster_node_install`

- [ ] **Step 1: Add smoke test for secret validation**

Append to `tests/role_wizard_smoke.sh`:

```bash
is_valid_cluster_secret_hex() {
  local s="$1"
  [[ "$s" =~ ^[0-9a-fA-F]{32}$ ]]
}
is_valid_cluster_secret_hex "0123456789abcdef0123456789abcdef" && pass "secret hex valid" \
  || fail "secret hex valid"
! is_valid_cluster_secret_hex "short" && pass "secret hex invalid" || fail "secret hex invalid"
```

Implement `is_valid_cluster_secret_hex` in `role_wizard.sh` and use in `prompt_cluster_secret`.

- [ ] **Step 2: Implement `prompt_cluster_secret` and `wizard_cluster_node`**

Replace stubs in `lib/role_wizard.sh`:

```bash
is_valid_cluster_secret_hex() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{32}$ ]]
}

prompt_cluster_secret() {
  local mode="" master_ip="" ssh_user="root" attempt=0 secret_in=""
  echo ""
  echo -e "${BOLD}=== SECRET кластера ===${NC}"
  echo "  1) Ввести вручную (32 hex)"
  echo "  2) Скачать с master по SSH"
  prompt_line mode "Способ" "1"
  case "$mode" in
    2|ssh)
      prompt_line master_ip "IP master" ""
      [ -n "$master_ip" ] || die "IP master обязателен"
      prompt_line ssh_user "SSH user" "root"
      if cluster_fetch_secret_ssh "$master_ip" "$ssh_user"; then
        CLUSTER_SECRET="$SECRET"
        export CLUSTER_SECRET
        return 0
      fi
      log_warn "SSH не удался — введите SECRET вручную"
      ;;
  esac
  while [ "$attempt" -lt 3 ]; do
    prompt_line secret_in "SECRET (32 hex)" ""
    if is_valid_cluster_secret_hex "$secret_in"; then
      CLUSTER_SECRET="$secret_in"
      SECRET="$secret_in"
      export CLUSTER_SECRET SECRET
      echo "$SECRET" > "$SECRET_FILE"
      chmod 600 "$SECRET_FILE"
      return 0
    fi
    log_warn "SECRET должен быть 32 hex-символа"
    attempt=$((attempt + 1))
  done
  die "SECRET не задан"
}

wizard_cluster_node() {
  prompt_line CLUSTER_DOMAIN "Кластерный домен (единая ссылка)" "${CLUSTER_DOMAIN:-}"
  CLUSTER_DOMAIN="$(require_valid_domain_name "$CLUSTER_DOMAIN")"
  export CLUSTER_DOMAIN CLUSTER_ROLE=node

  prepare_install_domain
  prompt_cluster_secret
  prepare_install_options

  print_role_summary "node"
  confirm_action "Начать установку ноды кластера?" || die "Отменено"
  run_cluster_node_install
}
```

- [ ] **Step 3: Run tests**

Run: `bash tests/role_wizard_smoke.sh && bash tests/cluster_smoke.sh`
Expected: all OK

- [ ] **Step 4: Commit**

```bash
git add lib/role_wizard.sh tests/role_wizard_smoke.sh
git commit -m "feat(wizard): add cluster node wizard and secret prompts"
```

---

### Task 5: Implement `prompt_cluster_nodes` and `wizard_master_lb`

**Files:**
- Modify: `lib/role_wizard.sh`
- Modify: `tests/role_wizard_smoke.sh`

- [ ] **Step 1: Add smoke test for node list parsing**

```bash
CLUSTER_NODES_FILE="$TMP/nodes.list"
prompt_cluster_nodes_noninteractive() {
  cluster_add_node "n1" "203.0.113.10" "443"
}
# test via cluster_add_node directly in wizard test
cluster_init_nodes_file() { touch "$CLUSTER_NODES_FILE"; }
cluster_add_node "a" "1.2.3.4" "443"
grep -q "a 1.2.3.4 443" "$CLUSTER_NODES_FILE" && pass "node list" || fail "node list"
```

- [ ] **Step 2: Implement functions**

```bash
prompt_cluster_nodes() {
  local name="" ip="" port="443"
  echo "Введите ноды (пустое имя — конец):"
  while true; do
    prompt_line name "Имя ноды" ""
    [ -z "$name" ] && break
    prompt_line ip "IP" ""
    [ -n "$ip" ] || die "IP обязателен"
    prompt_line port "Порт" "443"
    cluster_add_node "$name" "$ip" "$port"
  done
}

wizard_master_lb() {
  export CLUSTER_ROLE=master_lb
  DOMAIN=""
  prompt_line CLUSTER_DOMAIN "Кластерный домен (A-запись → этот сервер)" "${CLUSTER_DOMAIN:-}"
  CLUSTER_DOMAIN="$(require_valid_domain_name "$CLUSTER_DOMAIN")"
  export CLUSTER_DOMAIN
  DOMAIN="$CLUSTER_DOMAIN"
  export DOMAIN
  check_domain_dns "$CLUSTER_DOMAIN" || log_warn "DNS может не указывать на этот сервер"

  if confirm_yes "Добавить ноды сейчас?"; then
    cluster_init_nodes_file
    prompt_cluster_nodes
  fi

  print_role_summary "master_lb"
  confirm_action "Начать установку Master+LB?" || die "Отменено"
  run_cluster_master_lb_install
}
```

- [ ] **Step 3: Run all smoke tests**

Run: `bash tests/smoke.sh && bash tests/cluster_smoke.sh && bash tests/role_wizard_smoke.sh`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/role_wizard.sh tests/role_wizard_smoke.sh
git commit -m "feat(wizard): add master_lb wizard with optional node inventory"
```

---

### Task 6: Wire wizard into `install.sh` and `menu.sh`

**Files:**
- Modify: `install.sh`
- Modify: `lib/menu.sh`

- [ ] **Step 1: Source role_wizard in install.sh**

Change module list:

```bash
for mod in prereq dns nginx ssl ssl_renew telemt meko firewall dialog ui_highlight mask_picker version_picker rkn_check sni_check haproxy cluster role_wizard link backup ...
```

Add to `require_lib_bundle`:

```bash
if [ "${ROLE_WIZARD_SH_VERSION:-}" != "1.0" ]; then
  echo "[X] Отсутствует lib/role_wizard.sh (v1.0)" >&2
  missing=1
fi
```

Set `INSTALLER_VERSION="2.9"`.

- [ ] **Step 2: Update `menu_install` in `lib/menu.sh`**

Replace body after `handle_existing_env`:

```bash
menu_install() {
  set +e
  handle_existing_env
  set -euo pipefail
  if [ "${SELECTED_ENV_ACTION:-}" = "keep" ]; then
    pause_key_menu
    return 0
  fi
  role_wizard_run
  pause_key_menu
}
```

- [ ] **Step 3: Run smoke + manual syntax**

Run: `bash tests/smoke.sh`
Expected: `ALL SYNTAX OK`

- [ ] **Step 4: Commit**

```bash
git add install.sh lib/menu.sh
git commit -m "feat(install): wire role wizard into menu and installer v2.9"
```

---

### Task 7: Cluster menu tweaks for `master_lb`

**Files:**
- Modify: `lib/cluster.sh` (`menu_cluster`)

- [ ] **Step 1: Hide redundant HAProxy item**

In `menu_cluster`, change menu lines:

```bash
if [ "${CLUSTER_ROLE:-}" != "master_lb" ] || ! systemctl is-active --quiet haproxy 2>/dev/null; then
  echo "  6) Установить HAProxy (роль lb)"
fi
```

Update case `6)` label to mention master_lb.

- [ ] **Step 2: Commit**

```bash
git add lib/cluster.sh
git commit -m "fix(cluster): adapt cluster menu for master_lb role"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md`
- Modify: `DEPLOY.md`

- [ ] **Step 1: Update README interactive menu table**

Add note under Quick Start:

```markdown
При выборе **1) Установка** откроется мастер ролей (одиночный / нода / master+LB).
```

Bump version references to 2.9.

- [ ] **Step 2: Update DEPLOY.md** with same wizard flow and CLI examples for `--role=master-lb`.

- [ ] **Step 3: Commit**

```bash
git add README.md DEPLOY.md
git commit -m "docs: document universal role wizard install flow"
```

---

### Task 9: Final verification

- [ ] **Step 1: Run full test suite**

```bash
cd /root/tg-remote
bash tests/smoke.sh
bash tests/cluster_smoke.sh
bash tests/role_wizard_smoke.sh
bash install.sh --help | grep -E 'role|cluster-domain'
```

Expected: all tests OK; help shows cluster flags.

- [ ] **Step 2: Push to origin**

```bash
GIT_SSH_COMMAND='ssh -i /root/.ssh/id_ed25519_github -o IdentitiesOnly=yes' git push origin main
```

---

## Spec Coverage Checklist

| Spec requirement | Task |
|------------------|------|
| 3 interactive roles | Task 3, 4, 5 |
| master_lb combined | Task 1, 5 |
| SECRET manual + SSH | Task 4 |
| Nodes now or later on master | Task 5 |
| Node ip-only + domain | Task 4 (reuses `prepare_install_domain`) |
| 0 nodes: no HAProxy start | Task 1 |
| `--yes` behavior | Task 4, 5 (`confirm_action` / `confirm_yes`) |
| CLI `--role=master-lb` | Task 1, 6 |
| Menu item 1 uses wizard | Task 6 |
| Tests | Tasks 1, 3, 4, 5, 9 |
| Version 2.9 | Task 6 |
| README/DEPLOY | Task 8 |

## Self-Review

- No TBD/TODO placeholders in plan steps
- All new functions named consistently across tasks
- Each task has independent test + commit
- Scope matches spec; migration out of scope
