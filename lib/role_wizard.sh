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

wizard_cluster_node() { die "wizard_cluster_node: not implemented"; }
wizard_master_lb() { die "wizard_master_lb: not implemented"; }
