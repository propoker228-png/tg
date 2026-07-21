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
panel_generate_credentials() { :; }
panel_install() { :; }
panel_show_access_info() { :; }
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

# --- master_lb: cluster_fetch_secret_ssh behavioral (mock scp) ---
FAKE_REMOTE_SECRET="$TMP/remote-secret.txt"
echo "0123456789abcdef0123456789abcdef" > "$FAKE_REMOTE_SECRET"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/scp" <<EOF
#!/bin/bash
dest="\${!#}"
cp "$FAKE_REMOTE_SECRET" "\$dest"
exit 0
EOF
chmod +x "$TMP/bin/scp"
rm -f "$SECRET_FILE"
unset SECRET
export PATH="$TMP/bin:$PATH"
if cluster_fetch_secret_ssh "203.0.113.10" "root"; then
  pass "cluster_fetch_secret_ssh"
else
  fail "cluster_fetch_secret_ssh"
fi
if [ -f "$SECRET_FILE" ] \
  && [ "${SECRET:-}" = "0123456789abcdef0123456789abcdef" ]; then
  pass "cluster_fetch_secret_ssh exports SECRET"
else
  fail "cluster_fetch_secret_ssh exports SECRET (SECRET=${SECRET:-empty})"
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

# --- master_lb: 1 node reaches haproxy path (mocked deploy) ---
cat > "$CLUSTER_NODES_FILE" <<EOF
node1 203.0.113.10 443
EOF
export CLUSTER_DOMAIN="proxy.example.com"
HAPROXY_DEPLOY_CALLED=0
prereq_install_minimal() { :; }
haproxy_deploy() { HAPROXY_DEPLOY_CALLED=1; }
firewall_setup() { :; }
port_in_use() { return 1; }
haproxy_listens_443() { return 1; }
run_cluster_master_lb_install

if [ -s "$CLUSTER_NODES_FILE" ] && grep -q "node1" "$CLUSTER_NODES_FILE"; then
  pass "run_cluster_master_lb_install keeps nodes file with 1 node"
else
  fail "run_cluster_master_lb_install keeps nodes file with 1 node"
fi
if [ "$HAPROXY_DEPLOY_CALLED" -eq 1 ]; then
  pass "run_cluster_master_lb_install reaches haproxy with 1 node"
else
  fail "run_cluster_master_lb_install reaches haproxy with 1 node"
fi

# --- node agent tokens ---
CLUSTER_TOKENS_FILE="$TMP/test.tokens"
export CLUSTER_TOKENS_FILE
t=$(cluster_ensure_node_token "node1")
t2=$(cluster_ensure_node_token "node1")
if [ "${#t}" -eq 32 ] && [ "$t" = "$t2" ] && cluster_validate_node_token "node1" "$t"; then
  pass "node token ensure and validate"
else
  fail "node token ensure and validate"
fi
if ! cluster_validate_node_token "node1" "badtoken"; then
  pass "node token rejects invalid"
else
  fail "node token rejects invalid"
fi
cluster_add_node "tokennode" "203.0.113.99" "443"
if cluster_validate_node_token "tokennode" "$(awk '$1=="tokennode"{print $2}' "$CLUSTER_TOKENS_FILE")"; then
  pass "cluster_add_node ensures node token"
else
  fail "cluster_add_node ensures node token"
fi

# --- cluster domain migration (mock ssh) ---
MIGRATE_CLUSTER_FILE="$TMP/migrate.cluster"
MIGRATE_NODES_FILE="$TMP/migrate.nodes"
CLUSTER_HISTORY_FILE="$TMP/migrate.history"
CLUSTER_FILE="$MIGRATE_CLUSTER_FILE"
CLUSTER_NODES_FILE="$MIGRATE_NODES_FILE"
export CLUSTER_FILE CLUSTER_NODES_FILE CLUSTER_HISTORY_FILE
cat > "$CLUSTER_FILE" <<EOF
ROLE=master_lb
CLUSTER_DOMAIN=old.example.com
EOF
echo 'node1 203.0.113.10 443' > "$CLUSTER_NODES_FILE"
mkdir -p "$TMP/mock-etc/telemt"
cat > "$TMP/mock-etc/telemt/telemt.toml" <<EOF
public_host = "old.example.com"
tls_domain = "old.example.com"
EOF
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ssh" <<'SSHEOF'
#!/bin/bash
if [ "$1" = "-o" ]; then shift 5; fi
if [ "$1" = "bash" ] && [ "$2" = "-s" ]; then
  domain="$3"
  cfg="${MOCK_TELEMT_CFG:-/etc/telemt/telemt.toml}"
  sed -i "s/^public_host = .*/public_host = \"${domain}\"/" "$cfg"
  sed -i "s/^tls_domain = .*/tls_domain = \"${domain}\"/" "$cfg"
fi
exit 0
SSHEOF
chmod +x "$TMP/bin/ssh"
export MOCK_TELEMT_CFG="$TMP/mock-etc/telemt/telemt.toml"
export PATH="$TMP/bin:$PATH"
export CLUSTER_DOMAIN=old.example.com
export SECRET="0123456789abcdef0123456789abcdef"
if cluster_migrate_domain "new.example.com" && grep -q 'new.example.com' "$MOCK_TELEMT_CFG"; then
  pass "cluster_migrate_domain"
else
  fail "cluster_migrate_domain"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL CLUSTER SMOKE OK"
else
  exit 1
fi
