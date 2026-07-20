#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=ui_highlight.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui_highlight.sh"

ROLE_WIZARD_SH_VERSION="1.0"
SELECTED_INSTALL_ROLE=""

mask_secret_hex() {
  local s="$1"
  [ "${#s}" -ge 8 ] || { echo "****"; return; }
  echo "${s:0:4}...${s: -4}"
}

print_role_summary() {
  local role="$1"
  echo ""
  echo -e "${BOLD}=== Сводка установки ===${NC}"
  case "$role" in
    standalone)
      echo -e "  Роль:      ${CYAN}Одиночный прокси${NC}"
      echo -e "  Домен:     $(hl_domain "${DOMAIN:-н/д}")"
      ;;
    node)
      echo -e "  Роль:      ${CYAN}Нода кластера${NC}"
      echo -e "  Кластер:   $(hl_domain "${CLUSTER_DOMAIN:-н/д}")"
      echo -e "  Маска:     $(hl_domain "${DOMAIN:-н/д}")"
      echo -e "  SECRET:    ${CYAN}$(mask_secret_hex "${SECRET:-}")${NC}"
      ;;
    master_lb)
      echo -e "  Роль:      ${CYAN}Master + LB${NC}"
      echo -e "  Кластер:   $(hl_domain "${CLUSTER_DOMAIN:-н/д}")"
      if [ -f "${CLUSTER_NODES_FILE:-/etc/telemt-deploy.cluster.nodes}" ] \
        && [ -s "${CLUSTER_NODES_FILE:-/etc/telemt-deploy.cluster.nodes}" ]; then
        echo -e "  Ноды:      $(wc -l < "${CLUSTER_NODES_FILE}") шт."
      else
        echo -e "  Ноды:      ${YELLOW}0 (добавить позже)${NC}"
      fi
      ;;
  esac
  echo ""
}

prompt_install_role() {
  local choice="" current=""
  if [ -f /etc/telemt-deploy.cluster ]; then
    # shellcheck disable=SC1090
    source /etc/telemt-deploy.cluster
    current="${ROLE:-}"
    [ -n "$current" ] && log_info "Текущая роль: ${current}"
  fi
  while true; do
    echo ""
    echo -e "${BOLD}=== Выберите роль сервера ===${NC}"
    echo "  1) Одиночный прокси          (telemt + nginx + MEKO)"
    echo "  2) Нода кластера             (telemt + nginx + MEKO, общий SECRET)"
    echo "  3) Master + балансировщик    (HAProxy + управление кластером)"
    echo "  0) Отмена"
    prompt_line choice "Выбор" ""
    case "$choice" in
      1|standalone) SELECTED_INSTALL_ROLE=standalone; export SELECTED_INSTALL_ROLE; return 0 ;;
      2|node) SELECTED_INSTALL_ROLE=node; export SELECTED_INSTALL_ROLE; return 0 ;;
      3|master_lb|master|lb) SELECTED_INSTALL_ROLE=master_lb; export SELECTED_INSTALL_ROLE; return 0 ;;
      0) die "Установка отменена" ;;
      *) log_warn "Введите 1, 2, 3 или 0" ;;
    esac
  done
}

role_wizard_run() {
  prompt_install_role
  case "$SELECTED_INSTALL_ROLE" in
    standalone) wizard_standalone ;;
    node) wizard_cluster_node ;;
    master_lb) wizard_master_lb ;;
    *) die "Неизвестная роль: $SELECTED_INSTALL_ROLE" ;;
  esac
}

wizard_standalone() {
  prepare_install_domain
  prepare_install_options
  print_role_summary "standalone"
  confirm_action "Начать установку?" || die "Отменено"
  run_install_flow
}

is_valid_cluster_secret_hex() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{32}$ ]]
}

prompt_cluster_secret() {
  local mode="" master_ip="" ssh_user="root" attempt=0 secret_in=""
  echo ""
  echo -e "${BOLD}=== SECRET кластера ===${NC}"
  echo "  1) Ввести вручную (32 hex)"
  echo "  2) Скачать с master по SSH"
  prompt_line mode "Способ" "1"
  case "$mode" in
    2|ssh)
      prompt_line master_ip "IP master" ""
      [ -n "$master_ip" ] || die "IP master обязателен"
      prompt_line ssh_user "SSH user" "root"
      if cluster_fetch_secret_ssh "$master_ip" "$ssh_user"; then
        CLUSTER_SECRET="$SECRET"
        export CLUSTER_SECRET
        return 0
      fi
      log_warn "SSH не удался — введите SECRET вручную"
      ;;
  esac
  while [ "$attempt" -lt 3 ]; do
    prompt_line secret_in "SECRET (32 hex)" ""
    if is_valid_cluster_secret_hex "$secret_in"; then
      CLUSTER_SECRET="$secret_in"
      SECRET="$secret_in"
      export CLUSTER_SECRET SECRET
      echo "$SECRET" > "$SECRET_FILE"
      chmod 600 "$SECRET_FILE"
      return 0
    fi
    log_warn "SECRET должен быть 32 hex-символа"
    attempt=$((attempt + 1))
  done
  die "SECRET не задан"
}

wizard_cluster_node() {
  prompt_line CLUSTER_DOMAIN "Кластерный домен (единая ссылка)" "${CLUSTER_DOMAIN:-}"
  CLUSTER_DOMAIN="$(require_valid_domain_name "$CLUSTER_DOMAIN")"
  export CLUSTER_DOMAIN CLUSTER_ROLE=node

  prepare_install_domain
  prompt_cluster_secret
  prepare_install_options

  print_role_summary "node"
  confirm_action "Начать установку ноды кластера?" || die "Отменено"
  run_cluster_node_install
}
prompt_cluster_nodes() {
  local name="" ip="" port="443"
  echo "Введите ноды (пустое имя — конец):"
  while true; do
    prompt_line name "Имя ноды" ""
    [ -z "$name" ] && break
    prompt_line ip "IP" ""
    [ -n "$ip" ] || die "IP обязателен"
    prompt_line port "Порт" "443"
    cluster_add_node "$name" "$ip" "$port"
  done
}

wizard_master_lb() {
  export CLUSTER_ROLE=master_lb
  DOMAIN=""
  prompt_line CLUSTER_DOMAIN "Кластерный домен (A-запись → этот сервер)" "${CLUSTER_DOMAIN:-}"
  CLUSTER_DOMAIN="$(require_valid_domain_name "$CLUSTER_DOMAIN")"
  export CLUSTER_DOMAIN
  DOMAIN="$CLUSTER_DOMAIN"
  export DOMAIN
  check_domain_dns "$CLUSTER_DOMAIN" || log_warn "DNS может не указывать на этот сервер"

  if confirm_yes "Добавить ноды сейчас?"; then
    cluster_init_nodes_file
    prompt_cluster_nodes
  fi

  print_role_summary "master_lb"
  confirm_action "Начать установку Master+LB?" || die "Отменено"
  run_cluster_master_lb_install
}
