#!/bin/bash
# lib/prereq.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    curl wget tar jq openssl dnsutils \
    nginx certbot python3-certbot-nginx python3 \
    iptables ufw gettext-base dialog
}

setup_sysctl() {
  cat > /etc/sysctl.d/99-tg-keepalive.conf <<'EOF'
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
EOF
  cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  local iface
  iface=$(ip route | awk '/default/{print $5; exit}')
  tc qdisc replace dev "$iface" root fq 2>/dev/null || true
}

setup_telemt_user() {
  id telemt &>/dev/null || useradd -r -s /usr/sbin/nologin -d /opt/telemt telemt
  mkdir -p /opt/telemt/tlsfront /opt/telemt /etc/telemt /var/www/html/.well-known/acme-challenge
  chown -R telemt:telemt /opt/telemt
}

prereq_install() {
  install_packages
  setup_sysctl
  setup_telemt_user
  log_ok "Пакеты и sysctl настроены"
}
