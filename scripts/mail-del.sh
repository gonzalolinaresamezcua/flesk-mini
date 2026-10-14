#!/usr/bin/env bash
# Flesk — baja de buzón (fase 4)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk mail del <user@dominio> [--keep-data]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dirección de buzón"; fi

EMAIL_RAW="$1"
shift
KEEP_DATA=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-data) KEEP_DATA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

PARSED="$(parse_email "$EMAIL_RAW")" || die 2 "Email inválido: $EMAIL_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
EMAIL="${LOCAL_PART}@${DOMAIN}"

VMAIL_HOME="${VMAIL_HOME:-/var/vmail}"
MAILDIR_ABS="${VMAIL_HOME}/${DOMAIN}/${LOCAL_PART}"

lock "mail:$EMAIL"
trap 'unlock' EXIT

ROW="$(mysql_q -e "SELECT m.id, m.maildir FROM mailboxes m JOIN domains d ON d.id=m.domain_id
  WHERE d.name='${DOMAIN}' AND m.local_part='${LOCAL_PART}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$ROW" ]]; then
  log "INFO" "mail.del $EMAIL idempotente (no existía)"
  echo "OK mailbox=$EMAIL (no existía)"
  exit 0
fi
MB_ID="$(printf '%s' "$ROW" | awk '{print $1}')"
MAILDIR_DB="$(printf '%s' "$ROW" | awk '{print $2}')"
if [[ -n "$MAILDIR_DB" && "$MAILDIR_DB" == /* ]]; then
  MAILDIR_ABS="$MAILDIR_DB"
elif [[ -n "$MAILDIR_DB" ]]; then
  MAILDIR_ABS="${VMAIL_HOME}/${MAILDIR_DB%/}"
fi

# Borrar forwards asociados (FK CASCADE) y fila
mysql_q -e "DELETE FROM mailboxes WHERE id=${MB_ID} LIMIT 1;"

if [[ "$KEEP_DATA" -eq 1 ]]; then
  log "INFO" "Conservando Maildir $MAILDIR_ABS (--keep-data)"
else
  if [[ -d "$MAILDIR_ABS" ]]; then
    stamp="$(date '+%Y%m%d%H%M%S')"
    dest="$FRESK_BACKUPS/maildir_${DOMAIN}_${LOCAL_PART}.${stamp}"
    mkdir -p "$FRESK_BACKUPS"
    mv "$MAILDIR_ABS" "$dest"
    log "INFO" "Maildir archivado en $dest"
  fi
fi

log "INFO" "mail.del $EMAIL ok keep_data=$KEEP_DATA"
audit "cli" "mail.del" "$EMAIL" "ok" "keep_data=$KEEP_DATA"
echo "OK mailbox=$EMAIL deleted"
exit 0
