#!/usr/bin/env bash
# Flesk — operaciones masivas en httpdocs (root helper)
#   flesk files backup <dominio> <ruta-relativa-a-la-raíz-del-dominio>   copia tar.zst en /var/backups/flesk/pre-ai/
#   flesk files empty  <dominio> <ruta>   copia de seguridad + vacía la carpeta (no sigue symlinks)
# La ruta es relativa a /var/www/vhosts/<dominio>/ y debe estar dentro de httpdocs.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ACTION="${1:-}"; shift || true
[[ $# -eq 2 ]] || die 2 "Uso: flesk files backup|empty <dominio> <ruta>"
DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido"
REL="$2"
[[ -n "$REL" && ${#REL} -le 1024 && "$REL" != /* && "$REL" != *$'\n'* ]] || die 2 "Ruta inválida"
case "/$REL/" in */../*|*/./*) die 2 "Ruta con . o .. no permitida" ;; esac
[[ -n "$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' LIMIT 1;")" ]] || die 3 "Dominio no registrado"
VHOSTS_ROOT="${VHOSTS_ROOT:-/var/www/vhosts}"
DOCROOT="$VHOSTS_ROOT/$DOMAIN/httpdocs"
[[ -d "$DOCROOT" && ! -L "$DOCROOT" ]] || die 3 "Falta httpdocs"
DOCREAL="$(realpath -e -- "$DOCROOT")"
TARGET="$VHOSTS_ROOT/$DOMAIN/$REL"
[[ -d "$TARGET" && ! -L "$TARGET" ]] || die 3 "No es una carpeta"
REAL="$(realpath -e -- "$TARGET")"
case "$REAL/" in "$DOCREAL"/*) ;; *) die 2 "Fuera de httpdocs" ;; esac

BK_DIR=/var/backups/flesk/pre-ai
backup() {
  install -d -m 700 -o root -g root /var/backups/flesk "$BK_DIR"
  local slug out
  slug="$(printf '%s' "$REL" | tr '/' '_' | tr -cd 'A-Za-z0-9._-')"
  out="$BK_DIR/${DOMAIN}_${slug}_$(date '+%Y%m%d-%H%M%S').tar.zst"
  ( umask 077; tar --zstd -cf "$out" -C "$REAL" . )
  chmod 600 "$out"
  printf '%s' "$out"
}

FILES="$(find "$REAL" -mindepth 1 -xdev ! -type d | wc -l)"
DIRS="$(find "$REAL" -mindepth 1 -xdev -type d | wc -l)"
BYTES="$(du -sb "$REAL" 2>/dev/null | awk '{print $1}')"
case "$ACTION" in
  backup)
    OUT="$(backup)"
    audit "cli" "files.backup" "$DOMAIN:$REL" "ok" "$OUT"
    echo "OK backup=$OUT size=$(stat -c %s "$OUT") files=$FILES dirs=$DIRS"
    ;;
  empty)
    lock "files:$DOMAIN"; trap 'unlock' EXIT
    OUT="$(backup)"
    find "$REAL" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} +
    audit "cli" "files.empty" "$DOMAIN:$REL" "ok" "files=$FILES dirs=$DIRS bytes=$BYTES backup=$OUT"
    echo "OK emptied=$REL files=$FILES dirs=$DIRS bytes=$BYTES backup=$OUT backup_size=$(stat -c %s "$OUT")"
    ;;
  *) die 2 "Acción inválida" ;;
esac
