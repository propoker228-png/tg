#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BACKUP_SH_VERSION="1.0"

backup_collect_paths() {
  local domain="${1:-${DOMAIN:-}}"
  env_load_settings 2>/dev/null || true
  [ -n "$domain" ] || domain="${DOMAIN:-}"

  BACKUP_PATHS=()
  [ -f "$SECRET_FILE" ] && BACKUP_PATHS+=("$SECRET_FILE")
  [ -f "$STATE_FILE" ] && BACKUP_PATHS+=("$STATE_FILE")
  [ -f /etc/telemt/telemt.toml ] && BACKUP_PATHS+=("/etc/telemt/telemt.toml")
  [ -f /etc/nginx/sites-available/telemt-site ] && BACKUP_PATHS+=("/etc/nginx/sites-available/telemt-site")
  [ -d /opt/mtpr-simple ] && BACKUP_PATHS+=("/opt/mtpr-simple")
  if [ -n "$domain" ] && [ -d "/etc/letsencrypt/live/${domain}" ]; then
    BACKUP_PATHS+=("/etc/letsencrypt/live/${domain}")
  fi
}

backup_write_manifest() {
  local dest="$1" domain="${2:-${DOMAIN:-}}" ts paths_json
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  paths_json=$(printf '%s\n' "${BACKUP_PATHS[@]}" | jq -R . | jq -s .)
  jq -n \
    --arg domain "$domain" \
    --arg created_at "$ts" \
    --arg installer "${INSTALLER_VERSION:-unknown}" \
    --argjson paths "$paths_json" \
    '{domain: $domain, created_at: $created_at, installer_version: $installer, paths: $paths}' \
    > "$dest"
}

backup_create() {
  local domain archive tmpdir staging
  env_load_settings
  [ -n "${DOMAIN:-}" ] || die "Домен не задан — невозможно создать бэкап"
  domain="$DOMAIN"

  backup_collect_paths "$domain"
  [ "${#BACKUP_PATHS[@]}" -gt 0 ] || die "Нет файлов для бэкапа"

  archive="/root/telemt-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tmpdir=$(mktemp -d)
  staging="$tmpdir/staging"
  mkdir -p "$staging"

  backup_write_manifest "$staging/MANIFEST.json" "$domain"

  local p dest
  for p in "${BACKUP_PATHS[@]}"; do
    [ -e "$p" ] || continue
    dest="$staging$p"
    mkdir -p "$(dirname "$dest")"
    cp -a "$p" "$dest"
  done

  tar -czf "$archive" -C "$staging" .
  rm -rf "$tmpdir"
  log_ok "Бэкап создан: $archive"
  printf '%s\n' "$archive"
}

backup_restore() {
  local archive="$1" force="${2:-0}" tmpdir staging manifest domain current
  [ -f "$archive" ] || die "Архив не найден: $archive"

  env_load_settings 2>/dev/null || true
  current="${DOMAIN:-}"

  tmpdir=$(mktemp -d)
  tar -xzf "$archive" -C "$tmpdir"
  staging="$tmpdir"
  [ -f "$tmpdir/MANIFEST.json" ] || staging="$tmpdir/staging"
  manifest="$staging/MANIFEST.json"
  [ -f "$manifest" ] || die "MANIFEST.json не найден в архиве"

  domain=$(jq -r '.domain // empty' "$manifest")
  [ -n "$domain" ] || die "Домен не указан в MANIFEST.json"

  if [ -n "$current" ] && [ "$current" != "$domain" ] && [ "$force" != "1" ]; then
    die "Домен в архиве ($domain) ≠ текущий ($current). Используйте --force"
  fi

  if [ "$force" != "1" ]; then
    confirm_action "Восстановить бэкап для домена ${domain}?" || die "Отменено"
  fi

  systemctl stop telemt nginx mtpr-synfix 2>/dev/null || true

  local rel abs
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="$staging$rel"
    [ -e "$abs" ] || continue
    mkdir -p "$(dirname "$rel")"
    cp -a "$abs" "$rel"
  done < <(jq -r '.paths[]?' "$manifest")

  if [ -f "$staging$STATE_FILE" ]; then
    cp -a "$staging$STATE_FILE" "$STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    export DOMAIN SECRET AD_TAG
  fi

  systemctl daemon-reload
  systemctl start nginx telemt 2>/dev/null || true
  systemctl start mtpr-synfix 2>/dev/null || true

  rm -rf "$tmpdir"
  log_ok "Бэкап восстановлен для домена ${domain}"
}

backup_manifest_paths_json() {
  backup_collect_paths "${1:-example.com}"
  printf '%s\n' "${BACKUP_PATHS[@]}" | jq -R . | jq -s .
}
