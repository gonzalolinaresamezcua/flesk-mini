#!/usr/bin/env bash
# Flesk — zona DNS por defecto de un dominio
#   flesk dns init <dominio>            crea la zona completa si no hay registros; si los hay, solo republica
#   flesk dns init <dominio> --reset    "Restablecer DNS": copia de seguridad de los registros y zona por defecto
# Zona por defecto: NS ns1/ns2 (+glue), A/AAAA para @ www webmail mail smtp pop imap ftp,
# MX 10 mail, SPF con include:_spf.mail.<dominio>, DKIM default._domainkey, DMARC.
# IPs desde config (PUBLIC_IP / PUBLIC_IP6) o detectadas; nunca fijas en el código.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/dns.sh"

usage() { echo "Uso: flesk dns init <dominio> [--reset]" >&2; }

require_root
ensure_installed

[[ $# -ge 1 ]] || { usage; die 2 "Falta dominio"; }
DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
shift
RESET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) RESET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

DOM_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='$(dns_sql_escape "$DOMAIN")' LIMIT 1;")"
[[ -n "$DOM_ID" ]] || die 2 "Dominio no registrado en Flesk: $DOMAIN"

# DKIM (fuera del lock DNS: tiene el suyo)
DKIM_TXT=""
if [[ -x "$(command -v opendkim-genkey || true)" ]]; then
  DKIM_TXT="$(bash "$FRESK_ROOT/scripts/dkim.sh" ensure "$DOMAIN" 2>/dev/null | sed -n 's/^DKIM_TXT=//p' || true)"
fi
[[ -n "$DKIM_TXT" ]] || log "WARN" "dns-init: sin clave DKIM para $DOMAIN (¿opendkim-tools?)"

lock "dns:$DOMAIN"
trap 'unlock' EXIT

IPV4="$(fresk_ipv4)"
IPV6="$(fresk_ipv6)"
[[ -n "$IPV4" ]] || log "WARN" "dns-init: sin IPv4 pública; se omiten registros A"
[[ -n "$IPV6" ]] || log "INFO" "dns-init: sin IPv6 pública; se omiten registros AAAA"

COUNT="$(mysql_q -e "SELECT COUNT(*) FROM dns_records WHERE domain_id=${DOM_ID};")"

if [[ "$RESET" -eq 1 && "${COUNT:-0}" -gt 0 ]]; then
  mkdir -p "$FRESK_BACKUPS"
  BK="$FRESK_BACKUPS/dns_${DOMAIN}.$(date '+%Y%m%d%H%M%S').tsv"
  mysql_q -e "SELECT type, host, value, ttl FROM dns_records WHERE domain_id=${DOM_ID} ORDER BY id;" > "$BK"
  chmod 600 "$BK"
  mysql_q -e "DELETE FROM dns_records WHERE domain_id=${DOM_ID};"
  log "INFO" "dns-init: $COUNT registros de $DOMAIN guardados en $BK antes de restablecer"
  COUNT=0
fi

if [[ "${COUNT:-0}" -eq 0 ]]; then
  T="${DNS_TTL_DEFAULT}"
  V=()
  add() { V+=("(${DOM_ID}, '$1', '$2', '$(dns_sql_escape "$3")', ${T})"); }
  add NS '@' "ns1.${DOMAIN}"
  add NS '@' "ns2.${DOMAIN}"
  for h in @ www webmail mail smtp pop imap ftp ns1 ns2; do
    if [[ -n "$IPV4" ]]; then add A "$h" "$IPV4"; fi
    if [[ -n "$IPV6" ]]; then add AAAA "$h" "$IPV6"; fi
  done
  add MX '@' "10 mail.${DOMAIN}"
  add TXT '@' "v=spf1 include:_spf.mail.${DOMAIN} ~all"
  SPF_IPS=""
  if [[ -n "$IPV4" ]]; then SPF_IPS+=" ip4:${IPV4}"; fi
  if [[ -n "$IPV6" ]]; then SPF_IPS+=" ip6:${IPV6}"; fi
  add TXT '_spf.mail' "v=spf1${SPF_IPS} ~all"
  if [[ -n "$DKIM_TXT" ]]; then add TXT 'default._domainkey' "$DKIM_TXT"; fi
  add TXT '_dmarc' "v=DMARC1; p=quarantine; rua=mailto:postmaster@${DOMAIN}; fo=1"
  SQL="INSERT INTO dns_records (domain_id, type, host, value, ttl) VALUES $(IFS=,; echo "${V[*]}");"
  mysql_q -e "$SQL"
  log "INFO" "dns-init: zona por defecto (${#V[@]} registros) para $DOMAIN reset=$RESET"
else
  log "INFO" "dns-init: $DOMAIN ya tiene $COUNT registros; solo republica zona"
fi

if ! dns_publish_domain "$DOMAIN"; then
  audit "cli" "dns.init" "$DOMAIN" "fail" "checkzone"
  die 5 "dns-init: named-checkzone falló para $DOMAIN (zona no publicada)"
fi

dns_apply_ufw_public

audit "cli" "dns.init" "$DOMAIN" "ok" "$([[ $RESET -eq 1 ]] && echo reset || echo zone)"
echo "OK dns-init domain=$DOMAIN zone=$BIND_ZONES/db.$DOMAIN reset=$RESET"
exit 0
