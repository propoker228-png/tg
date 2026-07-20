#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HAPROXY_SH_VERSION="1.0"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
LB_PORT="${LB_PORT:-443}"

haproxy_install_package() {
  if command -v haproxy >/dev/null 2>&1; then
    log_info "HAProxy уже установлен: $(haproxy -v 2>&1 | head -1)"
    return 0
  fi
  log_info "Установка HAProxy..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq haproxy
  log_ok "HAProxy установлен"
}

haproxy_build_servers_block() {
  local name ip port line
  HAPROXY_SERVERS=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    read -r name ip port <<< "$line"
    [ -n "$name" ] && [ -n "$ip" ] || continue
    port="${port:-443}"
    HAPROXY_SERVERS+="    server ${name} ${ip}:${port} check inter 5s fall 3 rise 2"$'\n'
  done
  [ -n "$HAPROXY_SERVERS" ] || die "Список нод пуст — добавьте ноды в кластер"
}

haproxy_render_config() {
  local nodes_file="${1:-$CLUSTER_NODES_FILE}"
  [ -f "$nodes_file" ] || die "Файл нод не найден: $nodes_file"
  haproxy_build_servers_block < "$nodes_file"
  export LB_PORT HAPROXY_SERVERS
  envsubst '${LB_PORT} ${HAPROXY_SERVERS}' \
    < "$DEPLOY_ROOT/templates/haproxy.cfg.tpl" > "$HAPROXY_CFG"
  chmod 644 "$HAPROXY_CFG"
}

haproxy_validate_config() {
  haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1 \
    || die "Невалидный конфиг HAProxy — проверьте $HAPROXY_CFG"
}

haproxy_deploy() {
  haproxy_install_package
  haproxy_render_config
  haproxy_validate_config
  systemctl enable haproxy
  systemctl restart haproxy
  systemctl is-active --quiet haproxy || die "HAProxy не запустился"
  log_ok "HAProxy развёрнут на порту ${LB_PORT}"
}

haproxy_reload() {
  [ -f "$HAPROXY_CFG" ] || die "HAProxy не настроен"
  haproxy_render_config
  haproxy_validate_config
  systemctl reload haproxy || systemctl restart haproxy
  log_ok "HAProxy перезагружен"
}

haproxy_status_line() {
  if systemctl is-active --quiet haproxy 2>/dev/null; then
    echo -e "${GREEN}active${NC}"
  else
    echo -e "${RED}inactive${NC}"
  fi
}

haproxy_listens_443() {
  ss -tlnH "sport = :${LB_PORT}" 2>/dev/null | grep -q .
}
