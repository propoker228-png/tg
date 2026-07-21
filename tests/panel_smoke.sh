#!/bin/bash
# Panel API smoke tests (no root, no apt)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export PANEL_METRICS_DIR="$TMP/metrics"
export PANEL_CLUSTER_FILE="$TMP/cluster"
export PANEL_NODES_FILE="$TMP/nodes"
export PANEL_TOKENS_FILE="$TMP/tokens"
export PANEL_CREDENTIALS_FILE="$TMP/panel"
export PANEL_SECRET_FILE="$TMP/secret"
export PANEL_DEPLOY_ROOT="$ROOT"
export PANEL_MIGRATE_STUB="$TMP/migrate.txt"
mkdir -p "$PANEL_METRICS_DIR"

cat > "$PANEL_CLUSTER_FILE" <<EOF
ROLE=master_lb
CLUSTER_DOMAIN=proxy.example.com
EOF
echo 'node1 203.0.113.10 443' > "$PANEL_NODES_FILE"
echo 'node1 abcdef0123456789abcdef0123456789ab' > "$PANEL_TOKENS_FILE"
cat > "$PANEL_CREDENTIALS_FILE" <<EOF
PANEL_USER=admin
PANEL_PASS=testpass12345678
EOF
echo '0123456789abcdef0123456789abcdef' > "$PANEL_SECRET_FILE"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export PANEL_API_PORT="$PORT"
PANEL_PID=""
cleanup_server() {
  if [ -n "$PANEL_PID" ] && kill -0 "$PANEL_PID" 2>/dev/null; then
    kill "$PANEL_PID" 2>/dev/null || true
    wait "$PANEL_PID" 2>/dev/null || true
  fi
}
trap 'cleanup_server; rm -rf "$TMP"' EXIT

python3 "$ROOT/lib/panel_api.py" >/dev/null 2>&1 &
PANEL_PID=$!
for _ in $(seq 1 50); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/api/v1/cluster" 2>/dev/null || echo "000")
  if [ "$code" = "401" ]; then
    break
  fi
  sleep 0.1
done

# POST metrics with bearer token
HTTP=$(curl -sS -o "$TMP/post.json" -w "%{http_code}" \
  -X POST "http://127.0.0.1:${PORT}/api/v1/metrics" \
  -H "Authorization: Bearer abcdef0123456789abcdef0123456789ab" \
  -H "Content-Type: application/json" \
  -d '{"node":"node1","people":42,"tcp":128,"telemt_active":true,"ts":"2026-07-21T13:00:00Z"}')
if [ "$HTTP" = "200" ] && [ -f "$PANEL_METRICS_DIR/node1.json" ]; then
  pass "POST /api/v1/metrics"
else
  fail "POST /api/v1/metrics (http=$HTTP)"
fi

HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "http://127.0.0.1:${PORT}/api/v1/metrics" \
  -H "Authorization: Bearer badtoken" \
  -H "Content-Type: application/json" \
  -d '{"node":"node1","people":1,"tcp":1,"telemt_active":false}')
if [ "$HTTP" = "401" ]; then
  pass "POST /api/v1/metrics rejects bad token"
else
  fail "POST /api/v1/metrics rejects bad token (http=$HTTP)"
fi

# GET cluster with basic auth
curl -fsS -u admin:testpass12345678 "http://127.0.0.1:${PORT}/api/v1/cluster" > "$TMP/cluster.json"
if python3 - <<'PY' "$TMP/cluster.json"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cluster_domain"] == "proxy.example.com"
assert data["totals"]["people"] == 42
assert data["totals"]["tcp"] == 128
assert len(data["nodes"]) == 1
n = data["nodes"][0]
assert n["name"] == "node1"
assert n["people"] == 42
assert n["status"] in ("online", "stale", "offline")
assert "tg://proxy" in data["proxy_link"]
PY
then
  pass "GET /api/v1/cluster"
else
  fail "GET /api/v1/cluster"
fi

HTTP=$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/api/v1/cluster")
if [ "$HTTP" = "401" ]; then
  pass "GET /api/v1/cluster requires auth"
else
  fail "GET /api/v1/cluster requires auth (http=$HTTP)"
fi

# migrate stub
HTTP=$(curl -sS -o "$TMP/migrate.json" -w "%{http_code}" \
  -u admin:testpass12345678 \
  -X POST "http://127.0.0.1:${PORT}/api/v1/domain/migrate" \
  -H "Content-Type: application/json" \
  -d '{"domain":"new.example.com"}')
if [ "$HTTP" = "200" ] && [ "$(cat "$PANEL_MIGRATE_STUB")" = "new.example.com" ]; then
  pass "POST /api/v1/domain/migrate stub"
else
  fail "POST /api/v1/domain/migrate stub (http=$HTTP)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PANEL SMOKE OK"
else
  exit 1
fi
