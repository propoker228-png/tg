#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STUB_SITE_SH_VERSION="1.0"
STUB_SITE_DEFAULT="it-services"

STUB_SITE_IDS=(
  it-services
  managed-ftp
  global-cdn
  marketplace
  image-hosting
  auto-parts
  cloud-storage
  saas-analytics
  logistics
)

stub_site_label() {
  case "${1:-}" in
    it-services) echo "IT services (managed infrastructure)" ;;
    managed-ftp) echo "Managed FTP / file exchange" ;;
    global-cdn) echo "Global CDN" ;;
    marketplace) echo "B2B marketplace" ;;
    image-hosting) echo "Image hosting / media CDN" ;;
    auto-parts) echo "Auto parts e-commerce" ;;
    cloud-storage) echo "Cloud storage" ;;
    saas-analytics) echo "SaaS analytics platform" ;;
    logistics) echo "International logistics" ;;
    *) echo "${1:-unknown}" ;;
  esac
}

is_valid_stub_site() {
  local id="$1" known
  for known in "${STUB_SITE_IDS[@]}"; do
    [ "$known" = "$id" ] && return 0
  done
  return 1
}

stub_site_resolve() {
  local raw="${1:-}"
  raw="${raw// /-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    1|it|it-services|itservices) printf '%s' "it-services" ;;
    2|ftp|managed-ftp|managedftp) printf '%s' "managed-ftp" ;;
    3|cdn|global-cdn|globalcdn) printf '%s' "global-cdn" ;;
    4|market|marketplace|shop) printf '%s' "marketplace" ;;
    5|image|images|image-hosting|imagehosting|pix) printf '%s' "image-hosting" ;;
    6|auto|auto-parts|autoparts|parts) printf '%s' "auto-parts" ;;
    7|cloud|cloud-storage|cloudstorage|storage) printf '%s' "cloud-storage" ;;
    8|saas|analytics|saas-analytics) printf '%s' "saas-analytics" ;;
    9|logistics|freight|shipping) printf '%s' "logistics" ;;
    *)
      if is_valid_stub_site "$raw"; then
        printf '%s' "$raw"
      else
        return 1
      fi
      ;;
  esac
}

stub_site_template_dir() {
  local theme="${1:-$STUB_SITE_DEFAULT}"
  is_valid_stub_site "$theme" || theme="$STUB_SITE_DEFAULT"
  printf '%s' "$DEPLOY_ROOT/templates/sites/$theme"
}

pick_stub_site() {
  local choice="" resolved=""
  if [ -n "${STUB_SITE:-}" ]; then
    resolved=$(stub_site_resolve "$STUB_SITE") || die "Неизвестный сайт-заглушка: $STUB_SITE"
    STUB_SITE="$resolved"
    export STUB_SITE
    log_ok "Сайт-заглушка: $(stub_site_label "$STUB_SITE")"
    return 0
  fi

  if is_auto_mode; then
    STUB_SITE="$STUB_SITE_DEFAULT"
    export STUB_SITE
    log_info "Сайт-заглушка (по умолчанию): $(stub_site_label "$STUB_SITE")"
    return 0
  fi

  echo ""
  echo -e "${BOLD}=== Сайт-заглушка для TLS-маскировки ===${NC}"
  echo "  1) IT services — managed infrastructure"
  echo "  2) Managed FTP — enterprise file exchange"
  echo "  3) Global CDN — edge delivery network"
  echo "  4) Marketplace — B2B trading platform"
  echo "  5) Image hosting — media CDN & galleries"
  echo "  6) Auto parts — international spare parts store"
  echo "  7) Cloud storage — secure file sync"
  echo "  8) SaaS analytics — business intelligence"
  echo "  9) Logistics — freight & supply chain"
  while true; do
    prompt_line choice "Выбор [1-9]" "1"
    resolved=$(stub_site_resolve "$choice") && break
    log_warn "Введите номер от 1 до 9"
  done
  STUB_SITE="$resolved"
  export STUB_SITE
  log_ok "Сайт-заглушка: $(stub_site_label "$STUB_SITE")"
}

deploy_stub_site() {
  local theme="${STUB_SITE:-$STUB_SITE_DEFAULT}" dest="/var/www/html" src item base
  src="$(stub_site_template_dir "$theme")"
  mkdir -p "$dest/.well-known/acme-challenge"
  if [ ! -d "$src" ]; then
    log_warn "Шаблон $theme не найден — используем $STUB_SITE_DEFAULT"
    src="$(stub_site_template_dir "$STUB_SITE_DEFAULT")"
    theme="$STUB_SITE_DEFAULT"
  fi
  if [ -d "$src" ]; then
    for item in "$src"/*; do
      [ -e "$item" ] || continue
      base=$(basename "$item")
      rm -rf "$dest/$base"
      cp -a "$item" "$dest/"
    done
    log_ok "Сайт-заглушка развёрнут: $(stub_site_label "$theme")"
  else
    cp "$DEPLOY_ROOT/templates/index.html" "$dest/index.html"
    log_ok "Сайт-заглушка развёрнут (минимальный)"
  fi
}
