#!/usr/bin/env bash
# Flesk — baja de alias (fase 4)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk alias del <origen@dominio> [destino]" >&2
  echo "  Sin destino: elimina todos los alias de ese origen." >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta origen"; fi

SRC_RAW="$1"
DST_RAW="${2:-}"

PARSED="$(parse_email "$SRC_RAW")" || die 2 "Origen inválido: $SRC_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
SOURCE="${LOCAL_PART}@${DOMAIN}"

DOMAIN_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$DOMAIN_ID" ]]; then
  die 3 "Dominio no encontrado: $DOMAIN"
fi

if [[ -n "$DST_RAW" ]]; then
  DEST="$(valid_destination "$DST_RAW")" || die 2 "Destino inválido: $DST_RAW"
  mysql_q -e "DELETE FROM aliases WHERE domain_id=${DOMAIN_ID} AND source='${SOURCE}' AND destination='${DEST}';"
else
  mysql_q -e "DELETE FROM aliases WHERE domain_id=${DOMAIN_ID} AND source='${SOURCE}';"
fi

log "INFO" "alias.del $SOURCE ${DST_RAW:-*} ok"
audit "cli" "alias.del" "$SOURCE" "ok" "dest=${DST_RAW:-all}"
# Contestadores automáticos: los alias que entregan en un buzón cuentan como sus direcciones
php "$FRESK_ROOT/lib/mail-vacation.php" sync >/dev/null 2>&1 || log "WARN" "mail.vacation sync falló tras ${0##*/}"
echo "OK alias=$SOURCE deleted"
exit 0
