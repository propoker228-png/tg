#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROXY_MODE_SH_VERSION="1.0"
PROXY_MODE="${PROXY_MODE:-tls}"

proxy_mode_default() {
  PROXY_MODE=tls
  export PROXY_MODE
}

normalize_proxy_mode() {
  local raw="${1:-}"
  raw="$(trim_whitespace "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    tls|fake-tls|ee|"") PROXY_MODE=tls ;;
    secure|obfuscated2|dd) PROXY_MODE=secure ;;
    *) die "Неизвестный режим прокси: $raw (допустимо: tls, secure)" ;;
  esac
  export PROXY_MODE
}

proxy_mode_is_secure() {
  [ "${PROXY_MODE:-tls}" = "secure" ]
}

proxy_mode_label() {
  if proxy_mode_is_secure; then
    echo "Obfuscated2 (dd)"
  else
    echo "Fake TLS (ee)"
  fi
}

proxy_mode_link_kind() {
  if proxy_mode_is_secure; then
    echo "secure"
  else
    echo "tls"
  fi
}

proxy_mode_is_standalone_context() {
  local role="${SELECTED_INSTALL_ROLE:-${CLUSTER_ROLE:-standalone}}"
  [ "$role" = "standalone" ]
}

proxy_mode_force_tls_for_cluster() {
  local role="${CLUSTER_ROLE:-standalone}"
  case "$role" in
    standalone) return 0 ;;
  esac
  if [ "${PROXY_MODE:-tls}" = "secure" ]; then
    log_warn "Режим secure (dd) только для standalone — используем Fake TLS (ee)"
    PROXY_MODE=tls
    export PROXY_MODE
  fi
}

proxy_mode_warn_ip_only_secure() {
  if install_is_ip_only && proxy_mode_is_secure; then
    log_warn "Obfuscated2 (dd) по IP часто даёт задержку 15–20 с. Используйте свой домен."
  fi
}

pick_proxy_mode() {
  proxy_mode_force_tls_for_cluster
  proxy_mode_is_standalone_context || return 0
  if [ -n "${PROXY_MODE_CLI:-}" ]; then
    normalize_proxy_mode "$PROXY_MODE_CLI"
    proxy_mode_warn_ip_only_secure
    log_ok "Режим: $(proxy_mode_label)"
    return 0
  fi
  if is_auto_mode; then
    PROXY_MODE="${PROXY_MODE:-tls}"
    export PROXY_MODE
    proxy_mode_warn_ip_only_secure
    return 0
  fi
  has_tty || die "Выбор режима прокси требует TTY. Запустите: sudo bash install.sh"
  local choice=""
  while true; do
    echo ""
    echo -e "${BOLD}=== Режим прокси ===${NC}"
    echo "  1) Fake TLS (ee) — рекомендуется, маскировка под HTTPS"
    echo "  2) Obfuscated2 (dd) — random padding; рекомендуется свой домен"
    prompt_line choice "Выбор [1/2]" "1"
    case "$choice" in
      1|""|tls|ee) PROXY_MODE=tls; break ;;
      2|secure|dd) PROXY_MODE=secure; break ;;
      *) log_warn "Введите 1 или 2" ;;
    esac
  done
  export PROXY_MODE
  proxy_mode_warn_ip_only_secure
  log_ok "Режим: $(proxy_mode_label)"
}
