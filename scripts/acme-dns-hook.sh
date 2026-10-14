#!/usr/bin/env bash
# Flesk — hook de certbot para DNS-01 contra el BIND local (zona gestionada por Flesk)
#   acme-dns-hook.sh auth|cleanup   (certbot pasa CERTBOT_DOMAIN y CERTBOT_VALIDATION)
# Publica/retira el TXT _acme-challenge.<dominio> en dns_records y regenera la zona.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/dns.sh"

require_root
ACTION="${1:-}"
D_RAW="${CERTBOT_DOMAIN:-}"; D_RAW="${D_RAW#\*.}"
DOMAIN="$(valid_domain "$D_RAW")" || die 2 "CERTBOT_DOMAIN inválido"
VAL="${CERTBOT_VALIDATION:-}"
[[ "$VAL" =~ ^[A-Za-z0-9_-]{20,128}$ ]] || die 2 "CERTBOT_VALIDATION inválido"

# Zona: el dominio registrado en Flesk que contiene el nombre
ZONE="$DOMAIN"
while [[ "$ZONE" == *.* ]]; do
  ID="$(mysql_q -e "SELECT id FROM domains WHERE name='$(dns_sql_escape "$ZONE")' LIMIT 1;")"
  [[ -n "$ID" ]] && break
  ZONE="${ZONE#*.}"
done
[[ -n "${ID:-}" ]] || die 2 "Sin zona Flesk para $DOMAIN"
HOST="_acme-challenge"
[[ "$DOMAIN" != "$ZONE" ]] && HOST="_acme-challenge.${DOMAIN%.$ZONE}"

lock "dns:$ZONE"; trap 'unlock' EXIT
case "$ACTION" in
  auth)
    mysql_q -e "INSERT INTO dns_records (domain_id, type, host, value, ttl) VALUES (${ID}, 'TXT', '${HOST}', '${VAL}', 60);"
    dns_publish_domain "$ZONE" || die 5 "No se pudo publicar la zona $ZONE"
    for _ in $(seq 1 20); do
      dig +short TXT "$HOST.$ZONE" @127.0.0.1 2>/dev/null | grep -q "$VAL" && break
      sleep 1
    done
    sleep 3
    audit "cli" "acme.dns" "$ZONE" "ok" "auth $HOST"
    ;;
  cleanup)
    mysql_q -e "DELETE FROM dns_records WHERE domain_id=${ID} AND type='TXT' AND host='${HOST}' AND value='${VAL}';"
    dns_publish_domain "$ZONE" || true
    audit "cli" "acme.dns" "$ZONE" "ok" "cleanup $HOST"
    ;;
  *) die 2 "Uso: acme-dns-hook.sh auth|cleanup" ;;
esac
