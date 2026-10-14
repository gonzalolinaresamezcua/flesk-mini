#!/usr/bin/env bash
# Flesk — alta/actualización de registro DNS (fase 5)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/dns.sh"

usage() {
  echo "Uso: flesk dns set <dominio> <TYPE> <nombre> <valor> [--ttl N]" >&2
  echo "  TYPE: A AAAA MX CNAME TXT NS" >&2
  echo "  nombre: @ o etiqueta relativa (www, mail, ns1)" >&2
  echo "  MX valor: '10 mail.ejemplo.com' o 'mail.ejemplo.com'" >&2
}

require_root
ensure_installed

TTL="$DNS_TTL_DEFAULT"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ttl)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --ttl"
      TTL="$2"
      [[ "$TTL" =~ ^[0-9]+$ ]] || die 2 "TTL inválido"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ ${#ARGS[@]} -lt 4 ]]; then usage; die 2 "Faltan argumentos"; fi

DOMAIN="$(valid_domain "${ARGS[0]}")" || die 2 "Dominio inválido: ${ARGS[0]}"
TYPE="$(dns_valid_type "${ARGS[1]}")" || die 2 "Tipo DNS no permitido: ${ARGS[1]} (A|AAAA|MX|CNAME|TXT|NS)"
HOST="$(dns_valid_host "${ARGS[2]}")" || die 2 "Nombre de host inválido: ${ARGS[2]}"
VALUE_RAW="${ARGS[3]}"
# Si hay más args sin --ttl, unir como valor (espacios)
if [[ ${#ARGS[@]} -gt 4 ]]; then
  VALUE_RAW="${ARGS[*]:3}"
fi
VALUE="$(dns_sanitize_value "$VALUE_RAW" "$TYPE")" || die 2 "Valor rechazado (caracteres ; { } o saltos de línea)"
dns_valid_value_for_type "$TYPE" "$VALUE" || die 2 "Valor inválido para tipo $TYPE: $VALUE"

# Normalizar MX
if [[ "$TYPE" == "MX" && ! "$VALUE" =~ ^[0-9]+[[:space:]] ]]; then
  VALUE="10 $VALUE"
fi

lock "dns:$DOMAIN"
trap 'unlock' EXIT

DOM_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='$(dns_sql_escape "$DOMAIN")' LIMIT 1;")"
if [[ -z "$DOM_ID" ]]; then
  die 2 "Dominio no registrado: $DOMAIN"
fi

# Upsert semántico: un valor por (domain, type, host)
# CNAME no puede coexistir con otros tipos en el mismo owner
if [[ "$TYPE" == "CNAME" ]]; then
  mysql_q -e "
    DELETE FROM dns_records
    WHERE domain_id=${DOM_ID} AND host='$(dns_sql_escape "$HOST")';
  "
else
  mysql_q -e "
    DELETE FROM dns_records
    WHERE domain_id=${DOM_ID} AND host='$(dns_sql_escape "$HOST")' AND type='CNAME';
    DELETE FROM dns_records
    WHERE domain_id=${DOM_ID} AND type='${TYPE}' AND host='$(dns_sql_escape "$HOST")';
  "
fi
mysql_q -e "
  INSERT INTO dns_records (domain_id, type, host, value, ttl)
  VALUES (${DOM_ID}, '${TYPE}', '$(dns_sql_escape "$HOST")', '$(dns_sql_escape "$VALUE")', ${TTL});
"

# Si aún no hay zona (sin NS), inicializar mínimos sin pisar este registro
ZONE_FILE="$BIND_ZONES/db.$DOMAIN"
if [[ ! -f "$ZONE_FILE" ]]; then
  NS_COUNT="$(mysql_q -e "SELECT COUNT(*) FROM dns_records WHERE domain_id=${DOM_ID} AND type='NS';")"
  if [[ "${NS_COUNT:-0}" -eq 0 ]]; then
    IPV4="${PUBLIC_IP:-127.0.0.1}"
    mysql_q -e "
      INSERT INTO dns_records (domain_id, type, host, value, ttl) VALUES
        (${DOM_ID}, 'NS', '@', 'ns1.${DOMAIN}', ${DNS_TTL_DEFAULT}),
        (${DOM_ID}, 'A', 'ns1', '${IPV4}', ${DNS_TTL_DEFAULT});
    "
  fi
fi

if ! dns_publish_domain "$DOMAIN"; then
  audit "cli" "dns.set" "$DOMAIN" "fail" "$TYPE $HOST"
  die 5 "named-checkzone falló; registro en DB pero zona no publicada (restaurada)"
fi

audit "cli" "dns.set" "$DOMAIN" "ok" "$TYPE $HOST -> $VALUE"
echo "OK dns-set domain=$DOMAIN type=$TYPE host=$HOST value=$VALUE ttl=$TTL"
exit 0
