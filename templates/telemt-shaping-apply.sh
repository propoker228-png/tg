#!/bin/bash
set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/root/telemt-deploy}"
[ -f /etc/telemt-deploy.conf ] && # shellcheck disable=SC1091
  source /etc/telemt-deploy.conf

# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/stats.sh"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/monitor.sh"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/lib/shaping.sh"

shaping_apply
