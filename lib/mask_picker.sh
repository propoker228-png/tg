#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MASK_PICKER_SH_VERSION="1.0"
MASK_SCAN_PARALLEL="${MASK_SCAN_PARALLEL:-24}"
MASK_SCAN_TIMEOUT="${MASK_SCAN_TIMEOUT:-2}"

_mask_show() {
  if [ -w /dev/tty ] 2>/dev/null; then
    printf '%b\n' "$*" >/dev/tty
  else
    printf '%b\n' "$*" >&2
  fi
}

ensure_tls_domain() {
  [ -n "${DOMAIN:-}" ] || return 1
  TLS_DOMAIN="${TLS_DOMAIN:-$DOMAIN}"
  TLS_DOMAIN="$(require_valid_domain_name "$TLS_DOMAIN")"
  export TLS_DOMAIN
  return 0
}

mask_server_ipv4() {
  get_public_ip
}

mask_default_iface() {
  local iface=""
  iface=$(ip route show default 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
  }')
  if [ -n "$iface" ] && [ -d "/sys/class/net/${iface}" ]; then
    printf '%s' "$iface"
    return 0
  fi
  printf '%s' "eth0"
}

mask_detect_scan_cidr() {
  local my_ip="$1" iface ip_cidr prefix net
  iface=$(mask_default_iface)
  ip_cidr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
  if [ -z "$ip_cidr" ]; then
    printf '%s/24' "$my_ip"
    return 0
  fi
  prefix="${ip_cidr#*/}"
  if [ "$prefix" -lt 24 ] 2>/dev/null; then
    net=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${ip_cidr}', strict=False).supernet(new_prefix=24))" 2>/dev/null) || true
    [ -n "$net" ] && { printf '%s' "$net"; return 0; }
  fi
  printf '%s' "$ip_cidr"
}

mask_probe_ip_cert_names() {
  local ip="$1"
  timeout "$MASK_SCAN_TIMEOUT" openssl s_client -connect "${ip}:443" -servername "$ip" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null \
    | grep -oE 'DNS:[^,[:space:]]+' \
    | sed 's/^DNS://' \
    | grep -v '^\*' \
    | head -20
}

mask_scan_subnet_hosts() {
  local cidr="$1" my_ip="$2"
  local tmp out ip active=0 count hn
  tmp=$(mktemp)
  out=$(mktemp)

  python3 - "$cidr" "$my_ip" <<'PY' > "$tmp"
import ipaddress, sys
cidr, skip = sys.argv[1], sys.argv[2]
net = ipaddress.ip_network(cidr, strict=False)
for ip in net.hosts():
    if str(ip) != skip:
        print(ip)
PY

  count=$(wc -l < "$tmp" | tr -d '[:space:]')
  log_info "Сканирование HTTPS в ${cidr} (${count} IP, параллельно ${MASK_SCAN_PARALLEL})..."

  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    (
      if timeout 1 bash -c "echo >/dev/tcp/${ip}/443" 2>/dev/null; then
        while IFS= read -r hn; do
          [ -z "$hn" ] && continue
          is_valid_domain_name "$hn" || continue
          printf '%s|%s\n' "$hn" "$ip"
        done < <(mask_probe_ip_cert_names "$ip")
      fi
    ) >> "$out" &
    active=$((active + 1))
    if [ "$active" -ge "$MASK_SCAN_PARALLEL" ]; then
      wait -n 2>/dev/null || wait
      active=$((active - 1))
    fi
  done < "$tmp"
  wait

  sort -u "$out"
  rm -f "$tmp" "$out"
}

mask_pick_from_scan_results() {
  local -a results=()
  local choice="" i line hn ip

  mapfile -t results < <(mask_scan_subnet_hosts "$@")
  if [ "${#results[@]}" -eq 0 ]; then
    log_warn "В подсети не найдено HTTPS-сайтов с валидными именами в сертификате"
    return 1
  fi

  if [ "${#results[@]}" -gt 25 ]; then
    results=("${results[@]:0:25}")
    log_info "Показаны первые 25 результатов"
  fi

  while true; do
    _mask_show ""
    _mask_show "${BOLD}Выберите домен маскировки из соседних IP${NC}"
    for i in "${!results[@]}"; do
      IFS='|' read -r hn ip <<< "${results[$i]}"
      _mask_show "  $((i + 1))) ${hn}  ${GRAY}(${ip})${NC}"
    done
    _mask_show "  0) Назад"
    prompt_line choice "Выбор" ""
    case "$choice" in
      0|q|Q) return 1 ;;
    esac
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#results[@]}" ]; then
      IFS='|' read -r hn _ip <<< "${results[$((choice - 1))]}"
      TLS_DOMAIN="$(require_valid_domain_name "$hn")"
      export TLS_DOMAIN
      return 0
    fi
    log_warn "Введите число от 0 до ${#results[@]}"
  done
}

prepare_install_mask_domain() {
  local choice="" manual="" cidr my_ip

  [ -n "${DOMAIN:-}" ] || die "Домен обязателен"

  if [ -n "${TLS_DOMAIN:-}" ] && [ "${TLS_DOMAIN}" != "${DOMAIN}" ]; then
    TLS_DOMAIN="$(require_valid_domain_name "$TLS_DOMAIN")"
    export TLS_DOMAIN
    log_ok "Маскировка TLS: $(hl_domain "$TLS_DOMAIN") ${GRAY}(подключение: $(hl_domain "$DOMAIN"))${NC}"
    return 0
  fi

  if is_auto_mode; then
    ensure_tls_domain || die "Не удалось задать TLS_DOMAIN"
    return 0
  fi

  has_tty || die "Выбор маскировки требует TTY. Запустите: sudo bash install.sh"

  while true; do
    _mask_show ""
    _mask_show "${BOLD}Маскировка TLS (SNI для DPI)${NC}"
    _mask_show "  ${GRAY}Подключение клиентов:${NC} ${DOMAIN}:443"
    _mask_show "  1) Тот же домен (${DOMAIN})"
    _mask_show "  2) Другой домен вручную (чужой сайт для маскировки)"
    _mask_show "  3) Сканировать соседние IP в подсети сервера"
    _mask_show "  0) Отмена"
    prompt_line choice "Выбор" "1"
    case "$choice" in
      1|""|same)
        TLS_DOMAIN="$DOMAIN"
        break
        ;;
      2|manual)
        prompt_line manual "Домен маскировки (SNI)" ""
        manual="$(require_valid_domain_name "$manual")"
        TLS_DOMAIN="$manual"
        break
        ;;
      3|scan|neighbor)
        my_ip=$(mask_server_ipv4)
        cidr=$(mask_detect_scan_cidr "$my_ip")
        log_info "IP сервера: ${my_ip}, подсеть: ${cidr}"
        if mask_pick_from_scan_results "$cidr" "$my_ip"; then
          break
        fi
        ;;
      0|q|Q|exit|выход)
        die "Установка отменена"
        ;;
      *)
        log_warn "Введите 1, 2, 3 или 0"
        ;;
    esac
  done

  export TLS_DOMAIN
  if [ "$TLS_DOMAIN" = "$DOMAIN" ]; then
    log_ok "Маскировка TLS: тот же домен ($(hl_domain "$DOMAIN"))"
  else
    log_ok "Маскировка TLS: $(hl_domain "$TLS_DOMAIN") ${GRAY}(подключение: $(hl_domain "$DOMAIN"))${NC}"
  fi
}
