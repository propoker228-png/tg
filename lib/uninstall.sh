#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=zapret2.sh
source "$(dirname "${BASH_SOURCE[0]}")/zapret2.sh"

uninstall_all() {
  log_warn "Удаление telemt-deploy стека..."

  systemctl stop telemt mtpr-synfix tg-zapret2 2>/dev/null || true
  systemctl disable telemt mtpr-synfix tg-zapret2 2>/dev/null || true

  rm -f /etc/systemd/system/telemt.service /etc/systemd/system/mtpr-synfix.service
  systemctl stop telemt-shaping.timer telemt-shaping.service 2>/dev/null || true
  systemctl disable telemt-shaping.timer telemt-shaping.service 2>/dev/null || true
  rm -f /etc/systemd/system/telemt-shaping.service /etc/systemd/system/telemt-shaping.timer
  rm -f /usr/local/bin/telemt-shaping-apply.sh
  local iface
  iface=$(ip route | awk '/default/{print $5; exit}')
  [ -n "$iface" ] && tc qdisc replace dev "$iface" root fq 2>/dev/null || true
  rm -f /bin/telemt
  rm -rf /etc/telemt
  userdel telemt 2>/dev/null || true

  rm -f /etc/nginx/sites-enabled/telemt-site /etc/nginx/sites-enabled/telemt-acme-temp
  rm -f /etc/nginx/sites-available/telemt-site /etc/nginx/sites-available/telemt-acme-temp
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
  systemctl restart nginx 2>/dev/null || true

  iptables -t filter -D INPUT -j MTPR_SYNFIX 2>/dev/null || true
  iptables -t filter -F MTPR_SYNFIX 2>/dev/null || true
  iptables -t filter -X MTPR_SYNFIX 2>/dev/null || true
  zapret2_remove 2>/dev/null || true

  ufw delete allow 80/tcp 2>/dev/null || true
  ufw delete allow 443/tcp 2>/dev/null || true

  rm -rf /opt/mtpr-simple
  remove_tg_command
  rm -f "$STATE_FILE"

  if [ -f /etc/telemt-deploy.cluster ]; then
    # shellcheck disable=SC1090
    source /etc/telemt-deploy.cluster
    if [ "${ROLE:-}" = "lb" ]; then
      systemctl stop haproxy 2>/dev/null || true
      systemctl disable haproxy 2>/dev/null || true
    fi
  fi

  # SECRET_FILE и letsencrypt оставляем

  systemctl daemon-reload
  log_ok "Удаление завершено"
}
