# Cluster Admin Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a web admin panel on `master_lb` with push metrics from nodes, CLI parity, and automated cluster-domain migration over SSH.

**Architecture:** Python stdlib HTTP API on `127.0.0.1:19091`, nginx TLS on `:8443` serving static dashboard and proxying `/api/*`. Nodes run `telemt-agent.timer` posting metrics. Bash modules handle install, migrate, and CLI. Metrics stored as JSON files under `/var/lib/telemt-deploy/metrics/`.

**Tech Stack:** Bash 5.x, Python 3 (stdlib `http.server`), nginx, systemd timers, Ubuntu 22.04/24.04, existing telemt API `:9091` on nodes.

## Global Constraints

- Target installer version: **3.0** (`INSTALLER_VERSION="3.0"` in `install.sh`)
- Master proxy traffic stays on HAProxy **:443**; panel only on **:8443**
- Domain migration changes **only** `CLUSTER_DOMAIN` / `public_host` / `tls_domain` in `telemt.toml`; mask nginx domains unchanged
- Metrics via **push agent** (not SSH polling)
- Web panel: **public HTTPS** with **HTTP Basic Auth** (`PANEL_USER` / `PANEL_PASS`, generated at install)
- Node auth for metrics: **Bearer per-node token** in `/etc/telemt-deploy.cluster.tokens`
- Spec: `docs/superpowers/specs/2026-07-21-cluster-admin-panel-design.md`

---

## File Map

| File | Action |
|------|--------|
| `lib/panel.sh` | Create — panel install, credentials, firewall 8443 |
| `lib/panel_api.py` | Create — HTTP API |
| `lib/cluster_agent.sh` | Create — agent install/deploy |
| `lib/cluster_migrate.sh` | Create — `cluster_migrate_domain` |
| `lib/cluster_panel.sh` | Create — CLI status/monitor/credentials |
| `lib/cluster.sh` | Modify — tokens on add_node, panel hooks in master_lb install |
| `install.sh` | Modify — source modules, `cluster` subcommand, v3.0 |
| `lib/firewall.sh` | Modify — optional `8443` for panel |
| `lib/menu.sh` / `lib/cluster.sh` `menu_cluster` | Modify — new menu items |
| `templates/panel/index.html` | Create |
| `templates/nginx-panel.tpl` | Create |
| `templates/telemt-panel.service` | Create |
| `templates/telemt-agent.service` | Create |
| `templates/telemt-agent.sh.tpl` | Create |
| `tests/panel_smoke.sh` | Create |
| `tests/cluster_smoke.sh` | Modify — token tests |
| `README.md`, `DEPLOY.md` | Modify |

---

### Task 1: Node token inventory

**Files:**
- Modify: `lib/cluster.sh`
- Modify: `tests/cluster_smoke.sh`

**Interfaces:**
- Produces: `cluster_tokens_file()` → path `/etc/telemt-deploy.cluster.tokens`
- Produces: `cluster_ensure_node_token(name) -> token_hex32`
- Produces: `cluster_validate_node_token(name, token) -> 0|1`
- Modifies: `cluster_add_node` calls `cluster_ensure_node_token`

- [ ] **Step 1: Add failing test**

```bash
# tests/cluster_smoke.sh — before final exit
CLUSTER_TOKENS_FILE="$TMP/test.tokens"
cluster_ensure_node_token() { ... } # will source from cluster.sh
t=$(cluster_ensure_node_token "node1")
[ "${#t}" -eq 32 ] && cluster_validate_node_token "node1" "$t" && pass "node token" || fail "node token"
```

- [ ] **Step 2: Run test — expect fail**

Run: `bash tests/cluster_smoke.sh`

- [ ] **Step 3: Implement in `lib/cluster.sh`**

```bash
CLUSTER_TOKENS_FILE="/etc/telemt-deploy.cluster.tokens"

cluster_init_tokens_file() {
  if [ ! -f "$CLUSTER_TOKENS_FILE" ]; then
    touch "$CLUSTER_TOKENS_FILE"
    chmod 600 "$CLUSTER_TOKENS_FILE"
  fi
}

cluster_ensure_node_token() {
  local name="$1" token
  [ -n "$name" ] || return 1
  cluster_init_tokens_file
  token=$(awk -v n="$name" '$1==n {print $2; exit}' "$CLUSTER_TOKENS_FILE")
  if [ -z "$token" ]; then
    token=$(openssl rand -hex 16)
    echo "${name} ${token}" >> "$CLUSTER_TOKENS_FILE"
  fi
  printf '%s' "$token"
}

cluster_validate_node_token() {
  local name="$1" token="$2"
  [ -n "$name" ] && [ -n "$token" ] || return 1
  cluster_init_tokens_file
  awk -v n="$name" -v t="$token" '$1==n && $2==t {found=1} END{exit !found}' "$CLUSTER_TOKENS_FILE"
}
```

Append to `cluster_add_node` after adding line to nodes file:

```bash
cluster_ensure_node_token "$name" >/dev/null
```

- [ ] **Step 4: Run tests, commit**

```bash
bash tests/cluster_smoke.sh
git add lib/cluster.sh tests/cluster_smoke.sh
git commit -m "feat(cluster): add per-node agent token inventory"
```

---

### Task 2: Panel API server (Python)

**Files:**
- Create: `lib/panel_api.py`
- Create: `tests/panel_smoke.sh`

**Interfaces:**
- Produces: `PanelApiHandler` serving:
  - `POST /api/v1/metrics` — Bearer auth, writes `/var/lib/telemt-deploy/metrics/<node>.json`
  - `GET /api/v1/cluster` — Basic auth, reads cluster files + metrics
  - `POST /api/v1/domain/migrate` — Basic auth, shells `cluster_migrate_domain_cli NEW_DOMAIN` (stub until Task 5)

- [ ] **Step 1: Create `tests/panel_smoke.sh` skeleton**

Use `TMP` dir, set env:
```bash
export PANEL_METRICS_DIR="$TMP/metrics"
export PANEL_CLUSTER_FILE="$TMP/cluster"
export PANEL_NODES_FILE="$TMP/nodes"
export PANEL_TOKENS_FILE="$TMP/tokens"
export PANEL_CREDENTIALS_FILE="$TMP/panel"
export PANEL_SECRET_FILE="$TMP/secret"
mkdir -p "$PANEL_METRICS_DIR"
echo 'ROLE=master_lb' > "$PANEL_CLUSTER_FILE"
echo 'CLUSTER_DOMAIN=proxy.example.com' >> "$PANEL_CLUSTER_FILE"
echo 'node1 203.0.113.10 443' > "$PANEL_NODES_FILE"
echo 'node1 abcdef0123456789abcdef0123456789ab' > "$PANEL_TOKENS_FILE"
echo -e 'PANEL_USER=admin\nPANEL_PASS=testpass12345678' > "$PANEL_CREDENTIALS_FILE"
echo '0123456789abcdef0123456789abcdef' > "$PANEL_SECRET_FILE"
```

Start server in background on random port, test POST metrics + GET cluster with curl.

- [ ] **Step 2: Implement `lib/panel_api.py`**

Key structure (stdlib only):

```python
#!/usr/bin/env python3
"""telemt-deploy panel API — stdlib only."""
import base64, json, os, subprocess, sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from datetime import datetime, timezone

METRICS_DIR = Path(os.environ.get("PANEL_METRICS_DIR", "/var/lib/telemt-deploy/metrics"))
# ... load panel creds, tokens, cluster files

class PanelHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/api/v1/metrics":
            return self.handle_metrics()
        if self.path == "/api/v1/domain/migrate":
            return self.handle_migrate()
        self.send_error(404)
    def do_GET(self):
        if self.path == "/api/v1/cluster":
            return self.handle_cluster()
        self.send_error(404)
```

`handle_metrics`: parse JSON body, validate Bearer against tokens file, write metrics JSON with `received_at` UTC.

`handle_cluster`: require Basic auth, build nodes array merging inventory + metrics files + compute `last_seen_sec` and `status` (online <30s, stale <120s, else offline).

`handle_migrate`: parse `{"domain":"new.example.com"}`, call subprocess `bash -c 'source ...; cluster_migrate_domain_cli "$1"'`.

Listen: `127.0.0.1:19091` (env `PANEL_API_PORT`).

- [ ] **Step 3: Run panel smoke, commit**

```bash
bash tests/panel_smoke.sh
git add lib/panel_api.py tests/panel_smoke.sh
git commit -m "feat(panel): add Python API server for metrics and cluster status"
```

---

### Task 3: Panel install (nginx + systemd)

**Files:**
- Create: `lib/panel.sh`
- Create: `templates/nginx-panel.tpl`
- Create: `templates/telemt-panel.service`
- Create: `templates/panel/index.html` (minimal placeholder)

**Interfaces:**
- Produces: `panel_generate_credentials()` — writes `/etc/telemt-deploy.panel`
- Produces: `panel_install()` — nginx site, self-signed cert, static files, systemd enable

- [ ] **Step 1: `panel_generate_credentials`**

```bash
PANEL_SH_VERSION="1.0"
PANEL_CREDENTIALS_FILE="/etc/telemt-deploy.panel"
PANEL_STATIC_DIR="/opt/telemt-panel"
PANEL_API_PORT="${PANEL_API_PORT:-19091}"

panel_generate_credentials() {
  PANEL_USER="${PANEL_USER:-admin}"
  PANEL_PASS="${PANEL_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
  cat > "$PANEL_CREDENTIALS_FILE" <<EOF
PANEL_USER=$PANEL_USER
PANEL_PASS=$PANEL_PASS
EOF
  chmod 600 "$PANEL_CREDENTIALS_FILE"
  export PANEL_USER PANEL_PASS
}
```

- [ ] **Step 2: `templates/nginx-panel.tpl`**

```nginx
server {
    listen 8443 ssl;
    server_name _;
    ssl_certificate ${PANEL_SSL_CERT};
    ssl_certificate_key ${PANEL_SSL_KEY};
    root ${PANEL_STATIC_DIR};
    location /api/ {
        proxy_pass http://127.0.0.1:${PANEL_API_PORT};
        proxy_set_header Host $host;
    }
}
```

- [ ] **Step 3: `panel_install`**

- `apt-get install -y nginx` if missing (master_lb previously minimal)
- `openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/telemt-panel/key.pem -out /etc/telemt-panel/cert.pem -subj "/CN=telemt-panel"`
- Copy `templates/panel/index.html` → `/opt/telemt-panel/`
- Install `telemt-panel.service` running `python3 $DEPLOY_ROOT/lib/panel_api.py`
- Enable nginx site, `ufw allow 8443/tcp`
- `panel_show_access_info` — print `https://$(get_public_ip):8443`

- [ ] **Step 4: Wire into `run_cluster_master_lb_install`**

After `cluster_init_master`, call `panel_generate_credentials` + `panel_install` (even when 0 nodes).

- [ ] **Step 5: Commit**

```bash
git add lib/panel.sh templates/
git commit -m "feat(panel): install nginx dashboard on master_lb port 8443"
```

---

### Task 4: Push agent on nodes

**Files:**
- Create: `lib/cluster_agent.sh`
- Create: `templates/telemt-agent.sh.tpl`
- Create: `templates/telemt-agent.service`

**Interfaces:**
- Produces: `agent_install(master_url, node_name, node_token)`
- Produces: `cluster_deploy_agent_ssh(name, ip)` — SCP config + enable on remote

- [ ] **Step 1: `templates/telemt-agent.sh.tpl`**

```bash
#!/bin/bash
set -euo pipefail
source /etc/telemt-deploy.agent
PEOPLE=$(curl -fsS --max-time 2 http://127.0.0.1:9091/v1/stats/users/active-ips | ... count ...)
TCP=$(curl -fsS --max-time 2 http://127.0.0.1:9091/v1/users | ...)
TELEMT_ACTIVE=false; systemctl is-active --quiet telemt && TELEMT_ACTIVE=true
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -fsSk --max-time 5 -X POST "${MASTER_URL}/api/v1/metrics" \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"node\":\"${NODE_NAME}\",\"people\":${PEOPLE},\"tcp\":${TCP},\"telemt_active\":${TELEMT_ACTIVE},\"ts\":\"${TS}\"}"
```

Use `-k` for self-signed master cert in v1.

- [ ] **Step 2: systemd timer** — `OnUnitActiveSec=10` on `telemt-agent.service`

- [ ] **Step 3: `agent_install` + hook in `run_cluster_node_install`**

Prompt or use env `MASTER_PANEL_URL`, `NODE_NAME`, `NODE_TOKEN` from wizard/CLI flags:
- `--master-panel-url https://IP:8443`
- `--node-name node1` (default hostname -s)

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(agent): add telemt push agent for cluster metrics"
```

---

### Task 5: Domain migration

**Files:**
- Create: `lib/cluster_migrate.sh`

**Interfaces:**
- Produces: `cluster_migrate_domain(new_domain) -> 0|1`
- Produces: `cluster_migrate_domain_cli` — for panel_api subprocess

- [ ] **Step 1: Implement migration**

```bash
cluster_migrate_domain() {
  local new_domain="$1"
  new_domain="$(require_valid_domain_name "$new_domain")"
  cluster_load
  echo "${CLUSTER_DOMAIN}" > /etc/telemt-deploy.cluster.history
  CLUSTER_DOMAIN="$new_domain"
  cluster_save
  local name ip port line fail=0
  while IFS= read -r line; do
    read -r name ip port <<< "$line"
    cluster_migrate_node_ssh "$name" "$ip" "$new_domain" || fail=1
  done < "$CLUSTER_NODES_FILE"
  cluster_get_proxy_link
  log_warn "Обновите DNS: ${new_domain} → $(get_public_ip)"
  return "$fail"
}

cluster_migrate_node_ssh() {
  local name="$1" ip="$2" domain="$3" ssh_user="${CLUSTER_SSH_USER:-root}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" bash -s "$domain" <<'REMOTE'
domain="$1"
sed -i "s/^public_host = .*/public_host = \"${domain}\"/" /etc/telemt/telemt.toml
sed -i "s/^tls_domain = .*/tls_domain = \"${domain}\"/" /etc/telemt/telemt.toml
systemctl restart telemt
REMOTE
}
```

- [ ] **Step 2: Wire `panel_api.py` migrate handler to call this**

- [ ] **Step 3: Add test with mock ssh in `tests/panel_smoke.sh`**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(cluster): add automated cluster domain migration over SSH"
```

---

### Task 6: CLI `tg cluster …`

**Files:**
- Create: `lib/cluster_panel.sh`
- Modify: `install.sh` `dispatch_subcommand`

- [ ] **Step 1: Implement functions**

```bash
cluster_cli_status() { ... read metrics JSON, print table ... }
cluster_cli_monitor() { loop 4s like monitor.sh ... }
cluster_cli_panel_credentials() { source panel file, print URL }
cluster_cli_migrate_domain() { cluster_migrate_domain "$1" }
```

- [ ] **Step 2: Extend `dispatch_subcommand`**

```bash
cluster)
  shift
  case "${1:-}" in
    status) cluster_cli_status; exit 0 ;;
    monitor) cluster_cli_monitor; exit 0 ;;
    panel-credentials) cluster_cli_panel_credentials; exit 0 ;;
    migrate-domain) cluster_cli_migrate_domain "$2"; exit $? ;;
    *) die "tg cluster: status|monitor|panel-credentials|migrate-domain" ;;
  esac
  ;;
```

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(cli): add tg cluster status monitor and migrate commands"
```

---

### Task 7: Web dashboard UI

**Files:**
- Modify: `templates/panel/index.html`

- [ ] **Step 1: Build single-page dashboard**

- Login: fetch with `Authorization: Basic ` + btoa(user:pass) stored in sessionStorage after prompt
- Poll `GET /api/v1/cluster` every 5s
- Table: name, ip, status badge, people, tcp, haproxy_up
- Totals row
- Proxy link copy button
- Domain migrate form → `POST /api/v1/domain/migrate` with `{"domain":"..."}`

Keep inline CSS/JS, no build step.

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(panel): add web dashboard UI for cluster monitoring"
```

---

### Task 8: Menu integration + wizard flags

**Files:**
- Modify: `lib/cluster.sh` `menu_cluster`
- Modify: `lib/role_wizard.sh` `wizard_master_lb` / `wizard_cluster_node`
- Modify: `install.sh` — flags `--master-panel-url`, `--node-name`

- [ ] **Step 1: Add menu items 7-9 in `menu_cluster`**

- 7) Панель / учётные данные
- 8) Мониторинг кластера (live)
- 9) Сменить кластерный домен

- [ ] **Step 2: Wizard prompts for master URL on node install**

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(menu): integrate cluster panel into menu and wizard"
```

---

### Task 9: Version 3.0, docs, final tests

**Files:**
- Modify: `install.sh` `INSTALLER_VERSION="3.0"`
- Modify: `README.md`, `DEPLOY.md`
- Modify: `tests/smoke.sh` if needed

- [ ] **Step 1: Bump version, require_lib_bundle for new modules**

Add checks: `PANEL_SH_VERSION`, `CLUSTER_AGENT_SH_VERSION`, `CLUSTER_MIGRATE_SH_VERSION`, `CLUSTER_PANEL_SH_VERSION`

- [ ] **Step 2: Run full suite**

```bash
bash tests/smoke.sh
bash tests/cluster_smoke.sh
bash tests/role_wizard_smoke.sh
bash tests/panel_smoke.sh
```

- [ ] **Step 3: Update docs, commit, push**

```bash
git commit -m "chore: release telemt-deploy v3.0 with cluster admin panel"
```

---

## Spec Coverage Checklist

| Requirement | Task |
|-------------|------|
| Web panel :8443 | 3, 7 |
| Push agent | 4 |
| Per-node tokens | 1 |
| GET /api/v1/cluster | 2 |
| POST metrics | 2 |
| Domain migrate SSH | 5 |
| CLI parity | 6 |
| Menu items | 8 |
| master_lb install panel | 3 |
| node agent install | 4, 8 |
| v3.0 | 9 |

## Self-Review

- All spec requirements mapped to tasks
- No placeholder steps
- `panel_api.py` uses stdlib only per spec
- Migrate does not touch mask domains (only telemt.toml public_host/tls_domain)
