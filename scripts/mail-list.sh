#!/usr/bin/env bash
# Flesk — listado de buzones (fase 4)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed

FILTER_DOMAIN=""
if [[ $# -ge 1 ]]; then
  FILTER_DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
fi

if [[ -n "$FILTER_DOMAIN" ]]; then
  mysql_q -e "SELECT CONCAT(m.local_part,'@',d.name) AS email, m.quota_mb, m.maildir, m.active, m.created_at
    FROM mailboxes m JOIN domains d ON d.id=m.domain_id
    WHERE d.name='${FILTER_DOMAIN}'
    ORDER BY d.name, m.local_part;"
else
  mysql_q -e "SELECT CONCAT(m.local_part,'@',d.name) AS email, m.quota_mb, m.maildir, m.active, m.created_at
    FROM mailboxes m JOIN domains d ON d.id=m.domain_id
    ORDER BY d.name, m.local_part;"
fi
exit 0
