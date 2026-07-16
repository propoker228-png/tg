#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

firewall_setup() {
  ufw allow 80/tcp comment 'telemt-deploy nginx acme' 2>/dev/null || true
  ufw allow 443/tcp comment 'telemt-deploy telemt' 2>/dev/null || true
  ufw --force enable 2>/dev/null || true
  log_ok "UFW: 80/443 открыты"
}
