#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLUSTER_AGENT_SH_VERSION="1.0"
AGENT_CONFIG_FILE="/etc/telemt-deploy.agent"
AGENT_SCRIPT="/usr/local/bin/telemt-agent.sh"

agent_render_script() {
  cp "$DEPLOY_ROOT/templates/telemt-agent.sh.tpl" "$AGENT_SCRIPT"
  chmod 755 "$AGENT_SCRIPT"
}

agent_write_config() {
  local master_url="$1" node_name="$2" node_token="$3"
  cat > "$AGENT_CONFIG_FILE" <<EOF
MASTER_URL=$master_url
NODE_NAME=$node_name
NODE_TOKEN=$node_token
EOF
  chmod 600 "$AGENT_CONFIG_FILE"
}

agent_install_systemd() {
  cp "$DEPLOY_ROOT/templates/telemt-agent.service" /etc/systemd/system/telemt-agent.service
  cp "$DEPLOY_ROOT/templates/telemt-agent.timer" /etc/systemd/system/telemt-agent.timer
  systemctl daemon-reload
  systemctl enable telemt-agent.timer
  systemctl restart telemt-agent.timer
}

agent_install() {
  local master_url="$1" node_name="$2" node_token="$3"
  [ -n "$master_url" ] && [ -n "$node_name" ] && [ -n "$node_token" ] \
    || die "agent_install: master_url, node_name, node_token обязательны"

  master_url="${master_url%/}"
  agent_write_config "$master_url" "$node_name" "$node_token"
  agent_render_script
  agent_install_systemd
  log_ok "Агент метрик установлен → ${master_url} (нода ${node_name})"
}

cluster_deploy_agent_ssh() {
  local name="$1" ip="$2"
  local ssh_user="${CLUSTER_SSH_USER:-root}" token url tmp
  [ -n "$name" ] && [ -n "$ip" ] || return 1

  token=$(cluster_ensure_node_token "$name")
  url="${MASTER_PANEL_URL:-https://$(get_public_ip):8443}"
  url="${url%/}"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/telemt-deploy.agent" <<EOF
MASTER_URL=$url
NODE_NAME=$name
NODE_TOKEN=$token
EOF
  cp "$DEPLOY_ROOT/templates/telemt-agent.sh.tpl" "$tmp/telemt-agent.sh"
  chmod 755 "$tmp/telemt-agent.sh"
  cp "$DEPLOY_ROOT/templates/telemt-agent.service" "$tmp/telemt-agent.service"
  cp "$DEPLOY_ROOT/templates/telemt-agent.timer" "$tmp/telemt-agent.timer"

  log_info "Установка агента метрик на ${ssh_user}@${ip} (${name})..."
  scp -o BatchMode=yes -o ConnectTimeout=10 \
    "$tmp/telemt-deploy.agent" "${ssh_user}@${ip}:${AGENT_CONFIG_FILE}" \
    "$tmp/telemt-agent.sh" "${ssh_user}@${ip}:${AGENT_SCRIPT}" \
    "$tmp/telemt-agent.service" "$tmp/telemt-agent.timer" \
    "${ssh_user}@${ip}:/etc/systemd/system/" 2>/dev/null || {
    log_warn "Не удалось развернуть агент на ${name} (${ip})"
    return 1
  }

  ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" \
    "chmod 600 ${AGENT_CONFIG_FILE} && chmod 755 ${AGENT_SCRIPT} && systemctl daemon-reload && systemctl enable telemt-agent.timer && systemctl restart telemt-agent.timer" \
    2>/dev/null || {
    log_warn "Не удалось запустить агент на ${name} (${ip})"
    return 1
  }

  log_ok "Агент метрик развёрнут на ${name}"
}
