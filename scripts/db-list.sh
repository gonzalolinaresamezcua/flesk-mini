#!/usr/bin/env bash
# Flesk — listado de bases de datos de sitios (fase 6)
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
  mysql_q -e "SELECT d.name AS domain, db.db_name, db.db_user, db.created_at
    FROM \`databases\` db
    JOIN domains d ON d.id = db.domain_id
    WHERE d.name='${FILTER_DOMAIN}'
    ORDER BY d.name, db.db_name;"
else
  mysql_q -e "SELECT d.name AS domain, db.db_name, db.db_user, db.created_at
    FROM \`databases\` db
    JOIN domains d ON d.id = db.domain_id
    ORDER BY d.name, db.db_name;"
fi
exit 0
