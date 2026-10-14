#!/usr/bin/env bash
# Flesk — listado de registros DNS (fase 5)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/dns.sh"

usage() {
  echo "Uso: flesk dns list [dominio]" >&2
}

ensure_installed

DOMAIN_FILTER=""
if [[ $# -ge 1 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) DOMAIN_FILTER="$(valid_domain "$1")" || die 2 "Dominio inválido: $1" ;;
  esac
fi

WHERE=""
if [[ -n "$DOMAIN_FILTER" ]]; then
  WHERE="WHERE d.name='$(dns_sql_escape "$DOMAIN_FILTER")'"
fi

printf '%-24s %-6s %-16s %-40s %s\n' "DOMAIN" "TYPE" "HOST" "VALUE" "TTL"
mysql_q -e "
  SELECT CONCAT(d.name, 0x1f, r.type, 0x1f, r.host, 0x1f, r.value, 0x1f, r.ttl)
  FROM dns_records r
  JOIN domains d ON d.id = r.domain_id
  ${WHERE}
  ORDER BY d.name, FIELD(r.type,'NS','A','AAAA','MX','CNAME','TXT'), r.host, r.value;
" | while IFS=$'\x1f' read -r dom typ host value rttl; do
  [[ -n "${dom:-}" ]] || continue
  printf '%-24s %-6s %-16s %-40s %s\n' "$dom" "$typ" "$host" "$value" "$rttl"
done
exit 0
