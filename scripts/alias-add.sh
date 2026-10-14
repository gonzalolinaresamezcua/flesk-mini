#!/usr/bin/env bash
# Flesk — alta de alias (fase 4). No crea Maildir.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk alias add <origen@dominio> <destino@…>" >&2
}

require_root
ensure_installed

if [[ $# -lt 2 ]]; then usage; die 2 "Faltan origen y destino"; fi

SRC_RAW="$1"
DST_RAW="$2"

PARSED="$(parse_email "$SRC_RAW")" || die 2 "Origen inválido: $SRC_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
SOURCE="${LOCAL_PART}@${DOMAIN}"

DEST="$(valid_destination "$DST_RAW")" || die 2 "Destino inválido: $DST_RAW"

DOMAIN_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' AND status='active' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$DOMAIN_ID" ]]; then
  die 3 "Dominio no existe o no está active: $DOMAIN"
fi

# No chocar con buzón existente del mismo origen
MB="$(mysql_q -e "SELECT id FROM mailboxes WHERE domain_id=${DOMAIN_ID} AND local_part='${LOCAL_PART}' LIMIT 1;" 2>/dev/null || true)"
if [[ -n "$MB" ]]; then
  die 4 "Conflicto: $SOURCE ya es un buzón. Usa flesk forward add para reenvío."
fi

EXISTING="$(mysql_q -e "SELECT id FROM aliases WHERE domain_id=${DOMAIN_ID} AND source='${SOURCE}' AND destination='${DEST}' LIMIT 1;" 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
  log "INFO" "alias.add $SOURCE → $DEST idempotente"
  echo "OK alias=$SOURCE → $DEST (ya existía)"
  exit 0
fi

mysql_q -e "INSERT INTO aliases (domain_id, source, destination, active) VALUES (${DOMAIN_ID}, '${SOURCE}', '${DEST}', 1);"

log "INFO" "alias.add $SOURCE → $DEST ok"
audit "cli" "alias.add" "$SOURCE" "ok" "dest=$DEST"
# Contestadores automáticos: los alias que entregan en un buzón cuentan como sus direcciones
php "$FRESK_ROOT/lib/mail-vacation.php" sync >/dev/null 2>&1 || log "WARN" "mail.vacation sync falló tras ${0##*/}"
echo "OK alias=$SOURCE → $DEST"
exit 0
