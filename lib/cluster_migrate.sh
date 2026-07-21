#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLUSTER_MIGRATE_SH_VERSION="1.0"
CLUSTER_HISTORY_FILE="/etc/telemt-deploy.cluster.history"

cluster_migrate_node_ssh() {
  local name="$1" ip="$2" domain="$3" ssh_user="${CLUSTER_SSH_USER:-root}"
  [ -n "$name" ] && [ -n "$ip" ] && [ -n "$domain" ] || return 1
  log_info "Миграция домена на ноде ${name} (${ip})..."
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" bash -s "$domain" <<'REMOTE'
set -euo pipefail
domain="$1"
cfg="/etc/telemt/telemt.toml"
[ -f "$cfg" ] || exit 1
sed -i "s/^public_host = .*/public_host = \"${domain}\"/" "$cfg"
sed -i "s/^tls_domain = .*/tls_domain = \"${domain}\"/" "$cfg"
systemctl restart telemt
REMOTE
  then
    log_ok "Нода ${name}: telemt.toml обновлён"
    return 0
  fi
  log_warn "Нода ${name}: ошибка SSH-миграции"
  return 1
}

cluster_migrate_domain() {
  local new_domain="$1" line name ip port fail=0 old_domain
  [ -n "$new_domain" ] || die "Укажите новый домен"
  new_domain="$(require_valid_domain_name "$new_domain")"
  cluster_load
  [ -n "${CLUSTER_DOMAIN:-}" ] || die "CLUSTER_DOMAIN не задан"
  old_domain="$CLUSTER_DOMAIN"

  echo "$old_domain" > "$CLUSTER_HISTORY_FILE"
  chmod 600 "$CLUSTER_HISTORY_FILE"
  CLUSTER_DOMAIN="$new_domain"
  cluster_save

  cluster_init_nodes_file
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    read -r name ip port <<< "$line"
    cluster_migrate_node_ssh "$name" "$ip" "$new_domain" || fail=1
  done < "$CLUSTER_NODES_FILE"

  local link
  link=$(cluster_get_proxy_link 2>/dev/null || true)
  log_warn "Обновите DNS: ${new_domain} → $(get_public_ip)"
  [ -n "$link" ] && log_info "Новая ссылка: ${link}"
  return "$fail"
}

cluster_migrate_domain_cli() {
  cluster_migrate_domain "$1"
}
