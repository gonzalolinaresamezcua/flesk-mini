#!/usr/bin/env bash
# Flesk — baja de reenvío (fase 4)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk forward del <user@dominio> [destino]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta buzón"; fi

MB_RAW="$1"
DST_RAW="${2:-}"

PARSED="$(parse_email "$MB_RAW")" || die 2 "Buzón inválido: $MB_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
EMAIL="${LOCAL_PART}@${DOMAIN}"

MB_ID="$(mysql_q -e "SELECT m.id FROM mailboxes m JOIN domains d ON d.id=m.domain_id
  WHERE d.name='${DOMAIN}' AND m.local_part='${LOCAL_PART}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$MB_ID" ]]; then
  die 3 "Buzón no encontrado: $EMAIL"
fi

if [[ -n "$DST_RAW" ]]; then
  DEST="$(valid_destination "$DST_RAW")" || die 2 "Destino inválido: $DST_RAW"
  mysql_q -e "DELETE FROM forwards WHERE mailbox_id=${MB_ID} AND destination='${DEST}';"
else
  mysql_q -e "DELETE FROM forwards WHERE mailbox_id=${MB_ID};"
fi

log "INFO" "forward.del $EMAIL ${DST_RAW:-*} ok"
audit "cli" "forward.del" "$EMAIL" "ok" "dest=${DST_RAW:-all}"
echo "OK forward=$EMAIL deleted"
exit 0
