#!/usr/bin/env bash
# Flesk — reenvío externo de un buzón (fase 4). Conserva copia local.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk forward add <user@dominio> <externo@otro>" >&2
}

require_root
ensure_installed

if [[ $# -lt 2 ]]; then usage; die 2 "Faltan buzón y destino externo"; fi

MB_RAW="$1"
DST_RAW="$2"

PARSED="$(parse_email "$MB_RAW")" || die 2 "Buzón inválido: $MB_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
EMAIL="${LOCAL_PART}@${DOMAIN}"

DEST="$(valid_destination "$DST_RAW")" || die 2 "Destino inválido: $DST_RAW"
if [[ "$DEST" == "$EMAIL" ]]; then
  die 2 "El destino no puede ser el propio buzón"
fi

MB_ID="$(mysql_q -e "SELECT m.id FROM mailboxes m JOIN domains d ON d.id=m.domain_id
  WHERE d.name='${DOMAIN}' AND m.local_part='${LOCAL_PART}' AND m.active=1 LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$MB_ID" ]]; then
  die 3 "Buzón no encontrado o inactivo: $EMAIL"
fi

EXISTING="$(mysql_q -e "SELECT id FROM forwards WHERE mailbox_id=${MB_ID} AND destination='${DEST}' LIMIT 1;" 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
  log "INFO" "forward.add $EMAIL → $DEST idempotente"
  echo "OK forward=$EMAIL → $DEST (ya existía)"
  exit 0
fi

mysql_q -e "INSERT INTO forwards (mailbox_id, destination, active) VALUES (${MB_ID}, '${DEST}', 1);"

log "INFO" "forward.add $EMAIL → $DEST ok"
audit "cli" "forward.add" "$EMAIL" "ok" "dest=$DEST"
echo "OK forward=$EMAIL → $DEST (copia local conservada)"
exit 0
