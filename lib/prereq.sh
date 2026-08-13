#!/bin/bash
# lib/prereq.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PREREQ_SH_VERSION="1.1"

_prereq_pkg_for_cmd() {
  case "$1" in
    curl) echo curl ;;
    wget) echo wget ;;
    jq) echo jq ;;
    openssl) echo openssl ;;
    dig) echo dnsutils ;;
    tar) echo tar ;;
    nginx) echo nginx ;;
    certbot) echo certbot ;;
    python3) echo python3 ;;
    iptables) echo iptables ;;
    ufw) echo ufw ;;
    envsubst) echo gettext-base ;;
    dialog) echo dialog ;;
    ss|ip|tc) echo iproute2 ;;
    haproxy) echo haproxy ;;
    *) echo "$1" ;;
  esac
}

_prereq_add_unique() {
  local pkg="$1" existing
  for existing in "${_PREREQ_MISSING[@]}"; do
    [ "$existing" = "$pkg" ] && return 0
  done
  _PREREQ_MISSING+=("$pkg")
}

_prereq_install_missing() {
  local -a pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  log_info "Установка недостающих компонентов: ${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${pkgs[@]}"
  log_ok "Компоненты установлены: ${pkgs[*]}"
}

# Проверяет команды и ставит соответствующие deb-пакеты, если их нет.
ensure_commands() {
  local cmd pkg
  local -a _PREREQ_MISSING=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    pkg=$(_prereq_pkg_for_cmd "$cmd")
    _prereq_add_unique "$pkg"
  done
  _prereq_install_missing "${_PREREQ_MISSING[@]}"
}

# Проверяет deb-пакеты по имени (для зависимостей без отдельной CLI-команды).
ensure_packages() {
  local pkg
  local -a _PREREQ_MISSING=()
  for pkg in "$@"; do
    dpkg -s "$pkg" &>/dev/null 2>&1 && continue
    _prereq_add_unique "$pkg"
  done
  _prereq_install_missing "${_PREREQ_MISSING[@]}"
}

# Минимум для DNS, выбора версий и сетевых проверок до полной установки.
ensure_base_packages() {
  ensure_commands curl wget jq openssl dig ss
  ensure_packages ca-certificates
}

# Полный набор пакетов для standalone/node установки.
ensure_install_packages() {
  ensure_commands curl wget tar jq openssl dig nginx certbot python3 iptables ufw envsubst dialog ss tc
  ensure_packages ca-certificates python3-certbot-nginx
}

install_packages() {
  ensure_install_packages
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

setup_meko_sysctl() {
  cat > /etc/sysctl.d/99-tg-meko.conf <<'EOF'
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
EOF
  sysctl --system >/dev/null 2>&1 || true
}

prereq_install() {
  install_packages
  setup_sysctl
  setup_meko_sysctl
  setup_telemt_user
  log_ok "Пакеты и sysctl настроены"
}

prereq_install_minimal() {
  ensure_commands curl wget openssl ufw envsubst haproxy
  setup_sysctl
  log_ok "Минимальные пакеты для Master+LB установлены"
}
