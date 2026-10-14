#!/usr/bin/env bash
# Flesk — estado SSL (fase 3)
# Uso: flesk ssl status [dominio]
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk ssl status [dominio]" >&2
}

ensure_installed

DOMAIN_FILTER=""
if [[ $# -ge 1 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      DOMAIN_FILTER="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
      ;;
  esac
fi

PUBLIC_IP="${PUBLIC_IP:-}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"

printf '%-30s %-10s %-12s %-20s %s\n' "DOMINIO" "DB_STATUS" "VHOST" "NOT_AFTER" "CERT"
printf '%-30s %-10s %-12s %-20s %s\n' "-------" "---------" "-----" "---------" "----"

if [[ -n "$DOMAIN_FILTER" ]]; then
  SQL="SELECT d.name, COALESCE(c.status,'none'), COALESCE(c.not_after,'-'), COALESCE(c.path_fullchain,''), COALESCE(c.issuer,'-')
       FROM domains d LEFT JOIN ssl_certs c ON c.domain_id = d.id
       WHERE d.name='${DOMAIN_FILTER}';"
else
  SQL="SELECT d.name, COALESCE(c.status,'none'), COALESCE(c.not_after,'-'), COALESCE(c.path_fullchain,''), COALESCE(c.issuer,'-')
       FROM domains d LEFT JOIN ssl_certs c ON c.domain_id = d.id
       ORDER BY d.name;"
fi

ROWS="$(mysql_q -e "$SQL" 2>/dev/null || true)"
if [[ -z "$ROWS" ]]; then
  if [[ -n "$DOMAIN_FILTER" ]]; then
    die 3 "Dominio no encontrado: $DOMAIN_FILTER"
  fi
  echo "(sin dominios)"
  exit 0
fi

while IFS=$'\t' read -r name status not_after path_fc issuer || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" ]] && continue
  vhost="$NGINX_ENABLED/${name}.conf"
  vlabel="no-vhost"
  if [[ -f "$vhost" ]]; then
    if grep -q 'listen 443' "$vhost" 2>/dev/null; then
      vlabel="https"
    else
      vlabel="http"
    fi
  fi
  cert_ok="-"
  if [[ -n "$path_fc" && -f "$path_fc" ]]; then
    cert_ok="ok"
  elif [[ -n "$path_fc" ]]; then
    cert_ok="missing"
  fi
  printf '%-30s %-10s %-12s %-20s %s (%s)\n' "$name" "$status" "$vlabel" "${not_after:--}" "$cert_ok" "${issuer:--}"
done <<< "$ROWS"

exit 0
