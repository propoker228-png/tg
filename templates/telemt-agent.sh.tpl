#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
source /etc/telemt-deploy.agent

PEOPLE=0
TCP=0
TELEMT_ACTIVE=false

if systemctl is-active --quiet telemt 2>/dev/null; then
  TELEMT_ACTIVE=true
  PEOPLE=$(curl -fsS --max-time 2 http://127.0.0.1:9091/v1/stats/users/active-ips 2>/dev/null \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l | tr -d '[:space:]' || echo 0)
  TCP=$(curl -fsS --max-time 2 http://127.0.0.1:9091/v1/users 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin).get('data') or []
    print(sum(int(u.get('current_connections') or 0) for u in data))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -fsSk --max-time 5 -X POST "${MASTER_URL}/api/v1/metrics" \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"node\":\"${NODE_NAME}\",\"people\":${PEOPLE:-0},\"tcp\":${TCP:-0},\"telemt_active\":${TELEMT_ACTIVE},\"ts\":\"${TS}\"}"
