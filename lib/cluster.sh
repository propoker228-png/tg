#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLUSTER_SH_VERSION="1.0"
CLUSTER_FILE="/etc/telemt-deploy.cluster"
CLUSTER_NODES_FILE="/etc/telemt-deploy.cluster.nodes"
CLUSTER_TOKENS_FILE="/etc/telemt-deploy.cluster.tokens"

cluster_tokens_file() {
  printf '%s' "$CLUSTER_TOKENS_FILE"
}

cluster_init_tokens_file() {
  if [ ! -f "$CLUSTER_TOKENS_FILE" ]; then
    touch "$CLUSTER_TOKENS_FILE"
    chmod 600 "$CLUSTER_TOKENS_FILE"
  fi
}

cluster_ensure_node_token() {
  local name="$1" token
  [ -n "$name" ] || return 1
  cluster_init_tokens_file
  token=$(awk -v n="$name" '$1==n {print $2; exit}' "$CLUSTER_TOKENS_FILE")
  if [ -z "$token" ]; then
    token=$(openssl rand -hex 16)
    echo "${name} ${token}" >> "$CLUSTER_TOKENS_FILE"
  fi
  printf '%s' "$token"
}

cluster_validate_node_token() {
  local name="$1" token="$2"
  [ -n "$name" ] && [ -n "$token" ] || return 1
  cluster_init_tokens_file
  awk -v n="$name" -v t="$token" '$1==n && $2==t {found=1} END{exit !found}' "$CLUSTER_TOKENS_FILE"
}

cluster_load() {
  if [ -f "$CLUSTER_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CLUSTER_FILE"
    CLUSTER_ROLE="${ROLE:-${CLUSTER_ROLE:-standalone}}"
  else
    CLUSTER_ROLE="${CLUSTER_ROLE:-standalone}"
  fi
  CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-}"
  CLUSTER_SSH_USER="${CLUSTER_SSH_USER:-root}"
  export CLUSTER_ROLE CLUSTER_DOMAIN CLUSTER_SSH_USER
}

cluster_save() {
  cat > "$CLUSTER_FILE" <<EOF
ROLE=${CLUSTER_ROLE}
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
SSH_USER=${CLUSTER_SSH_USER:-root}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$CLUSTER_FILE"
}

cluster_init_nodes_file() {
  if [ ! -f "$CLUSTER_NODES_FILE" ]; then
    touch "$CLUSTER_NODES_FILE"
    chmod 600 "$CLUSTER_NODES_FILE"
  fi
}

cluster_init_master() {
  local domain="$1"
  [ -n "$domain" ] || die "CLUSTER_DOMAIN обязателен для --role=master"
  CLUSTER_ROLE=master
  CLUSTER_DOMAIN="$domain"
  CLUSTER_SSH_USER="${CLUSTER_SSH_USER:-root}"
  cluster_save
  cluster_init_nodes_file
  if declare -f telemt_generate_secret >/dev/null 2>&1; then
    telemt_generate_secret
  else
    SECRET=$(openssl rand -hex 16)
    echo "$SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    export SECRET
  fi
  log_ok "Кластер инициализирован: ${CLUSTER_DOMAIN}"
}

cluster_add_node() {
  local name="$1" ip="$2" port="${3:-443}"
  [ -n "$name" ] && [ -n "$ip" ] || die "Формат ноды: name:ip:port"
  cluster_init_nodes_file
  if grep -qE "^${name}[[:space:]]" "$CLUSTER_NODES_FILE" 2>/dev/null; then
    sed -i "/^${name}[[:space:]]/d" "$CLUSTER_NODES_FILE"
  fi
  echo "${name} ${ip} ${port}" >> "$CLUSTER_NODES_FILE"
  cluster_ensure_node_token "$name" >/dev/null
  log_ok "Нода добавлена: ${name} ${ip}:${port}"
}

cluster_remove_node() {
  local name="$1"
  [ -n "$name" ] || return 1
  cluster_init_nodes_file
  if grep -qE "^${name}[[:space:]]" "$CLUSTER_NODES_FILE" 2>/dev/null; then
    sed -i "/^${name}[[:space:]]/d" "$CLUSTER_NODES_FILE"
    log_ok "Нода удалена: ${name}"
    return 0
  fi
  log_warn "Нода не найдена: ${name}"
  return 1
}

cluster_list_nodes() {
  cluster_init_nodes_file
  if [ ! -s "$CLUSTER_NODES_FILE" ]; then
    return 0
  fi
  cat "$CLUSTER_NODES_FILE"
}

cluster_check_node_tcp() {
  local ip="$1" port="${2:-443}"
  timeout 3 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null
}

cluster_node_status_label() {
  local ip="$1" port="${2:-443}"
  if cluster_check_node_tcp "$ip" "$port"; then
    echo -e "${GREEN}UP${NC}"
  else
    echo -e "${RED}DOWN${NC}"
  fi
}

cluster_import_secret() {
  if [ -n "${CLUSTER_SECRET:-}" ]; then
    echo "$CLUSTER_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    SECRET="$CLUSTER_SECRET"
    export SECRET
    log_info "Секрет импортирован из --cluster-secret"
    return 0
  fi
  if [ -f "$SECRET_FILE" ]; then
    SECRET=$(cat "$SECRET_FILE")
    export SECRET
    return 0
  fi
  return 1
}

cluster_fetch_secret_ssh() {
  local master_ip="$1" ssh_user="${2:-root}"
  [ -n "$master_ip" ] || return 1
  log_info "Получение SECRET с ${ssh_user}@${master_ip}..."
  if scp -o BatchMode=yes -o ConnectTimeout=10 \
    "${ssh_user}@${master_ip}:${SECRET_FILE}" "$SECRET_FILE" 2>/dev/null; then
    chmod 600 "$SECRET_FILE"
    SECRET=$(cat "$SECRET_FILE")
    export SECRET
    log_ok "SECRET получен с master"
    return 0
  fi
  log_warn "Не удалось получить SECRET по SSH с ${master_ip}"
  return 1
}

cluster_sync_secret_ssh() {
  local name ip port ssh_user line
  cluster_load
  cluster_init_nodes_file
  [ -f "$SECRET_FILE" ] || die "Секрет не найден: $SECRET_FILE"
  ssh_user="${CLUSTER_SSH_USER:-root}"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    read -r name ip port <<< "$line"
    [ -n "$ip" ] || continue
    log_info "Синхронизация секрета → ${ssh_user}@${ip}..."
    if scp -o BatchMode=yes -o ConnectTimeout=10 \
      "$SECRET_FILE" "${ssh_user}@${ip}:${SECRET_FILE}" 2>/dev/null; then
      ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" \
        "chmod 600 ${SECRET_FILE}" 2>/dev/null || true
      log_ok "Секрет скопирован на ${name} (${ip})"
    else
      log_warn "Не удалось скопировать секрет на ${name} (${ip}) — проверьте SSH"
    fi
  done < "$CLUSTER_NODES_FILE"
}

cluster_domain_to_hex() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

cluster_build_ee_secret() {
  local host="$1" secret="$2"
  if [[ "$secret" == ee* ]] || [[ "$secret" == dd* ]]; then
    echo "$secret"
  else
    echo "ee$(cluster_domain_to_hex "$host")${secret}"
  fi
}

cluster_build_proxy_link() {
  local host="$1" secret="$2" ee
  ee=$(cluster_build_ee_secret "$host" "$secret")
  echo "tg://proxy?server=${host}&port=443&secret=${ee}"
}

cluster_get_proxy_link() {
  cluster_load
  env_load_settings

  local link=""
  link=$(fetch_proxy_link 2>/dev/null || true)

  if [ -n "$link" ] && [ -n "${CLUSTER_DOMAIN:-}" ]; then
    if echo "$link" | grep -q "server=${CLUSTER_DOMAIN}"; then
      echo "$link"
      return 0
    fi
  fi

  if [ -n "${CLUSTER_DOMAIN:-}" ] && [ -n "${SECRET:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "
import urllib.parse
host = '${CLUSTER_DOMAIN}'
secret = '${SECRET}'
if secret.startswith('ee') or secret.startswith('dd'):
    ee = secret
else:
    ee = 'ee' + host.encode().hex() + secret
q = urllib.parse.urlencode({'server': host, 'port': '443', 'secret': ee})
print('tg://proxy?' + q)
" 2>/dev/null && return 0
    fi
    cluster_build_proxy_link "${CLUSTER_DOMAIN}" "${SECRET}"
    return 0
  fi

  [ -n "$link" ] && echo "$link"
}

cluster_show_status() {
  local name ip port line
  cluster_load
  env_load_settings

  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Кластер telemt-deploy${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════${NC}"
  echo -e "  Роль:           ${CYAN}${CLUSTER_ROLE:-standalone}${NC}"
  echo -e "  Домен ссылки:   ${CYAN}${CLUSTER_DOMAIN:-н/д}${NC}"
  echo -e "  HAProxy:        $(haproxy_status_line 2>/dev/null || echo 'н/д')"
  echo ""
  echo -e "  ${BOLD}Ноды:${NC}"
  if [ -f "$CLUSTER_NODES_FILE" ] && [ -s "$CLUSTER_NODES_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      [ -z "$line" ] && continue
      read -r name ip port <<< "$line"
      port="${port:-443}"
      printf "    %-12s %-18s %s\n" "$name" "${ip}:${port}" "$(cluster_node_status_label "$ip" "$port")"
    done < "$CLUSTER_NODES_FILE"
  else
    echo "    (нет зарегистрированных нод)"
  fi
  echo ""
  local link
  link=$(cluster_get_proxy_link 2>/dev/null || true)
  if [ -n "$link" ]; then
    echo -e "  ${BOLD}Единая ссылка:${NC}"
    echo -e "  ${CYAN}${link}${NC}"
  fi
  echo -e "${BOLD}══════════════════════════════════════════════${NC}"
  echo ""
}

cluster_register_self_node() {
  local name ip
  name="${CLUSTER_NODE_NAME:-$(hostname -s)}"
  ip=$(get_public_ip)
  cluster_add_node "$name" "$ip" 443
}

run_cluster_lb_install() {
  cluster_load
  [ -n "${CLUSTER_DOMAIN:-}" ] || die "--cluster-domain обязателен для --role=lb"

  if [ -n "${CLUSTER_NODES:-}" ]; then
    local spec name ip port
    for spec in $CLUSTER_NODES; do
      IFS=: read -r name ip port <<< "$spec"
      cluster_add_node "$name" "$ip" "${port:-443}"
    done
  fi

  CLUSTER_ROLE=lb
  cluster_save
  cluster_init_nodes_file

  if port_in_use "$LB_PORT" && ! haproxy_listens_443; then
    die "Порт ${LB_PORT} занят другим процессом"
  fi

  haproxy_deploy
  firewall_setup
  cluster_show_status
  log_ok "LB установлен для ${CLUSTER_DOMAIN}"
}

run_cluster_node_install() {
  cluster_load
  [ -n "${CLUSTER_DOMAIN:-}" ] || die "--cluster-domain обязателен для --role=node"
  [ -n "${DOMAIN:-}" ] || die "--domain обязателен для --role=node (домен маски ноды)"

  CLUSTER_ROLE=node
  cluster_save

  cluster_import_secret || telemt_generate_secret
  export CLUSTER_DOMAIN CLUSTER_ROLE

  run_install_flow

  cluster_register_self_node
  log_info "Нода зарегистрирована в кластере ${CLUSTER_DOMAIN}"
}

run_cluster_master_init() {
  cluster_init_master "${CLUSTER_DOMAIN}"
  cluster_show_status
}

run_cluster_master_lb_install() {
  cluster_load
  [ -n "${CLUSTER_DOMAIN:-}" ] || die "CLUSTER_DOMAIN обязателен для master+lb"

  if [ -n "${CLUSTER_NODES:-}" ]; then
    local spec name ip port
    for spec in $CLUSTER_NODES; do
      IFS=: read -r name ip port <<< "$spec"
      cluster_add_node "$name" "$ip" "${port:-443}"
    done
  fi

  cluster_init_master "${CLUSTER_DOMAIN}"
  CLUSTER_ROLE=master_lb
  cluster_save

  if [ ! -s "$CLUSTER_NODES_FILE" ]; then
    log_warn "Ноды не добавлены — HAProxy не запускается"
    log_info "Добавьте ноды: меню → 12) Кластер / мульти-прокси"
    cluster_show_status
    return 0
  fi

  if port_in_use "$LB_PORT" && ! haproxy_listens_443; then
    die "Порт ${LB_PORT} занят другим процессом"
  fi

  prereq_install_minimal
  haproxy_deploy
  firewall_setup
  cluster_show_status
  log_ok "Master+LB установлен для ${CLUSTER_DOMAIN}"
}

menu_cluster() {
  local c="" name ip port spec
  cluster_load
  env_load_settings

  while true; do
    clear
    cluster_show_status
    echo "  1) Инициализировать кластер (master)"
    echo "  2) Добавить ноду"
    echo "  3) Удалить ноду"
    echo "  4) Пересобрать HAProxy"
    echo "  5) Синхронизировать SECRET на ноды (SSH)"
    if [ "${CLUSTER_ROLE:-}" != "master_lb" ] || ! systemctl is-active --quiet haproxy 2>/dev/null; then
      echo "  6) Установить HAProxy (роль lb / master_lb)"
    fi
    echo "  0) Назад"
    prompt_line c "Выбор" ""
    case "$c" in
      1)
        prompt_line CLUSTER_DOMAIN "Кластерный домен" "${CLUSTER_DOMAIN:-}"
        export CLUSTER_DOMAIN
        confirm_dialog "Инициализировать кластер ${CLUSTER_DOMAIN}?" || continue
        run_cluster_master_init
        pause_key_menu
        ;;
      2)
        prompt_line name "Имя ноды" ""
        prompt_line ip "IP ноды" ""
        prompt_line port "Порт" "443"
        cluster_add_node "$name" "$ip" "$port"
        if systemctl is-active --quiet haproxy 2>/dev/null; then
          haproxy_reload
        fi
        pause_key_menu
        ;;
      3)
        prompt_line name "Имя ноды для удаления" ""
        cluster_remove_node "$name"
        if systemctl is-active --quiet haproxy 2>/dev/null; then
          haproxy_reload
        fi
        pause_key_menu
        ;;
      4)
        if [ ! -f "$CLUSTER_NODES_FILE" ] || [ ! -s "$CLUSTER_NODES_FILE" ]; then
          log_warn "Сначала добавьте ноды"
          pause_key_menu
          continue
        fi
        haproxy_reload
        pause_key_menu
        ;;
      5)
        cluster_sync_secret_ssh
        pause_key_menu
        ;;
      6)
        prompt_line CLUSTER_DOMAIN "Кластерный домен" "${CLUSTER_DOMAIN:-}"
        export CLUSTER_DOMAIN
        echo "Введите ноды (name:ip:port), пустая строка — конец:"
        while true; do
          prompt_line spec "Нода" ""
          [ -z "$spec" ] && break
          IFS=: read -r name ip port <<< "$spec"
          cluster_add_node "$name" "$ip" "${port:-443}"
        done
        CLUSTER_ROLE=lb
        cluster_save
        haproxy_deploy
        pause_key_menu
        ;;
      0) break ;;
      *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
  done
}
