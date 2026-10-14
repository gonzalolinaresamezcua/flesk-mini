#!/usr/bin/env bash
# Flesk — baja de registro DNS (fase 5)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/dns.sh"

usage() {
  echo "Uso: flesk dns del <dominio> <TYPE> <nombre> [valor]" >&2
}

require_root
ensure_installed

if [[ $# -lt 3 ]]; then usage; die 2 "Faltan argumentos"; fi

DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
TYPE="$(dns_valid_type "$2")" || die 2 "Tipo DNS no permitido: $2"
HOST="$(dns_valid_host "$3")" || die 2 "Nombre de host inválido: $3"
VALUE_FILTER="${4:-}"

lock "dns:$DOMAIN"
trap 'unlock' EXIT

DOM_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='$(dns_sql_escape "$DOMAIN")' LIMIT 1;")"
if [[ -z "$DOM_ID" ]]; then
  die 2 "Dominio no registrado: $DOMAIN"
fi

if [[ -n "$VALUE_FILTER" ]]; then
  VALUE_FILTER="$(dns_sanitize_value "$VALUE_FILTER")" || die 2 "Valor inválido"
  mysql_q -e "
    DELETE FROM dns_records
    WHERE domain_id=${DOM_ID} AND type='${TYPE}' AND host='$(dns_sql_escape "$HOST")'
      AND value='$(dns_sql_escape "$VALUE_FILTER")';
  "
else
  mysql_q -e "
    DELETE FROM dns_records
    WHERE domain_id=${DOM_ID} AND type='${TYPE}' AND host='$(dns_sql_escape "$HOST")';
  "
fi

# No borrar NS/SOA de facto dejando zona vacía sin NS: avisar si no queda NS
NS_LEFT="$(mysql_q -e "SELECT COUNT(*) FROM dns_records WHERE domain_id=${DOM_ID} AND type='NS';")"
if [[ "${NS_LEFT:-0}" -eq 0 ]]; then
  log "WARN" "dns-del: no quedan registros NS para $DOMAIN"
fi

REC_LEFT="$(mysql_q -e "SELECT COUNT(*) FROM dns_records WHERE domain_id=${DOM_ID};")"
if [[ "${REC_LEFT:-0}" -eq 0 ]]; then
  dns_remove_domain_zone "$DOMAIN"
  audit "cli" "dns.del" "$DOMAIN" "ok" "$TYPE $HOST (zona vacía eliminada)"
  echo "OK dns-del domain=$DOMAIN type=$TYPE host=$HOST (zona eliminada)"
  exit 0
fi

if ! dns_publish_domain "$DOMAIN"; then
  audit "cli" "dns.del" "$DOMAIN" "fail" "$TYPE $HOST"
  die 5 "named-checkzone falló tras borrar; zona restaurada"
fi

audit "cli" "dns.del" "$DOMAIN" "ok" "$TYPE $HOST"
echo "OK dns-del domain=$DOMAIN type=$TYPE host=$HOST"
exit 0
