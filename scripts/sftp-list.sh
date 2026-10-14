#!/usr/bin/env bash
# Flesk — listado de usuarios SFTP (fase 7)
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
  mysql_q -e "SELECT d.name AS domain, s.username, s.system_user, s.created_at
    FROM sftp_users s
    JOIN domains d ON d.id = s.domain_id
    WHERE d.name='${FILTER_DOMAIN}'
    ORDER BY d.name, s.username;"
else
  mysql_q -e "SELECT d.name AS domain, s.username, s.system_user, s.created_at
    FROM sftp_users s
    JOIN domains d ON d.id = s.domain_id
    ORDER BY d.name, s.username;"
fi
exit 0
