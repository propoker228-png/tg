#!/bin/bash
# Cluster and HAProxy smoke tests (no root, no apt, no system changes)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/telemt.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/haproxy.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cluster.sh"

export DEPLOY_ROOT="$ROOT"
CLUSTER_NODES_FILE="$TMP/test.nodes"
CLUSTER_FILE="$TMP/test.cluster"
SECRET_FILE="$TMP/test-secret.txt"
export CLUSTER_NODES_FILE CLUSTER_FILE SECRET_FILE

cluster_init_nodes_file
cluster_add_node "node1" "203.0.113.10" "443"
cluster_add_node "node2" "203.0.113.11" "443"

if cluster_list_nodes | grep -q "node1"; then
  pass "cluster_add_node"
else
  fail "cluster_add_node"
fi

cluster_remove_node "node1"
if ! cluster_list_nodes | grep -q "node1"; then
  pass "cluster_remove_node"
else
  fail "cluster_remove_node"
fi

cat > "$CLUSTER_NODES_FILE" <<EOF
node1 203.0.113.10 443
node2 203.0.113.11 443
EOF
export LB_PORT=443
HAPROXY_CFG="$TMP/haproxy.cfg"
haproxy_build_servers_block < "$CLUSTER_NODES_FILE"
export HAPROXY_SERVERS
envsubst '${LB_PORT} ${HAPROXY_SERVERS}' \
  < "$ROOT/templates/haproxy.cfg.tpl" > "$HAPROXY_CFG"

if grep -q "server node1 203.0.113.10:443 check" "$HAPROXY_CFG" \
  && grep -q "balance source" "$HAPROXY_CFG" \
  && grep -q "mode tcp" "$HAPROXY_CFG"; then
  pass "haproxy template render"
else
  fail "haproxy template render"
  cat "$HAPROXY_CFG" >&2
fi

export DOMAIN="mask.example.com"
export CLUSTER_DOMAIN="proxy.example.com"
export CLUSTER_ROLE="node"
export PUBLIC_HOST="$CLUSTER_DOMAIN"
export TELEMT_TLS_DOMAIN="$CLUSTER_DOMAIN"
export SECRET="0123456789abcdef0123456789abcdef"
export AD_TAG_LINE=""
TOML_OUT="$TMP/telemt.toml"
envsubst '${DOMAIN} ${SECRET} ${AD_TAG_LINE} ${PUBLIC_HOST} ${TELEMT_TLS_DOMAIN}' \
  < "$ROOT/templates/telemt.toml.tpl" > "$TOML_OUT"

if grep -q 'public_host = "proxy.example.com"' "$TOML_OUT" \
  && grep -q 'tls_domain = "proxy.example.com"' "$TOML_OUT"; then
  pass "telemt.toml cluster public_host/tls_domain"
else
  fail "telemt.toml cluster public_host/tls_domain"
  cat "$TOML_OUT" >&2
fi

export CLUSTER_DOMAIN="proxy.example.com"
export SECRET="0123456789abcdef0123456789abcdef"
link=$(cluster_get_proxy_link 2>/dev/null || true)
if echo "$link" | grep -q "server=proxy.example.com" \
  && echo "$link" | grep -q "tg://proxy"; then
  pass "cluster_get_proxy_link"
else
  fail "cluster_get_proxy_link (got: ${link:-empty})"
fi

export CLUSTER_DOMAIN="proxy.example.com"
cluster_init_master "proxy.example.com"
if [ -f "$SECRET_FILE" ] && [ -f "$CLUSTER_FILE" ]; then
  pass "cluster_init_master"
else
  fail "cluster_init_master"
fi

# --- master_lb: cluster_fetch_secret_ssh exists ---
if declare -f cluster_fetch_secret_ssh >/dev/null 2>&1; then
  pass "cluster_fetch_secret_ssh defined"
else
  fail "cluster_fetch_secret_ssh defined"
fi

# --- master_lb: init without nodes (no haproxy cfg required) ---
> "$CLUSTER_NODES_FILE"
export CLUSTER_DOMAIN="proxy.example.com"
export CLUSTER_ROLE=master_lb
env_load_settings() { :; }
run_cluster_master_lb_install

if grep -q '^ROLE=master_lb' "$CLUSTER_FILE" 2>/dev/null; then
  pass "run_cluster_master_lb_install sets master_lb role"
else
  fail "run_cluster_master_lb_install sets master_lb role"
fi

if [ -f "$SECRET_FILE" ] && [ -s "$SECRET_FILE" ]; then
  pass "run_cluster_master_lb_install saves secret"
else
  fail "run_cluster_master_lb_install saves secret"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL CLUSTER SMOKE OK"
else
  exit 1
fi
