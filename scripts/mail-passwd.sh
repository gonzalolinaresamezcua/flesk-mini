#!/usr/bin/env bash
# Flesk — cambio de contraseña de buzón (fase 4)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk mail passwd <user@dominio> [--password <claro>]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dirección de buzón"; fi

EMAIL_RAW="$1"
shift
PLAIN_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password|--pass)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --password"
      PLAIN_PASS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die 2 "Argumento desconocido: $1"
      ;;
  esac
done

PARSED="$(parse_email "$EMAIL_RAW")" || die 2 "Email inválido: $EMAIL_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
EMAIL="${LOCAL_PART}@${DOMAIN}"

lock "mail:$EMAIL"
trap 'unlock' EXIT

MB_ID="$(mysql_q -e "SELECT m.id FROM mailboxes m JOIN domains d ON d.id=m.domain_id
  WHERE d.name='${DOMAIN}' AND m.local_part='${LOCAL_PART}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$MB_ID" ]]; then
  die 3 "Buzón no encontrado: $EMAIL"
fi

if [[ -z "$PLAIN_PASS" ]]; then
  PLAIN_PASS="$(gen_password)"
fi
PASS_HASH="$(hash_mailbox_password "$PLAIN_PASS")"
PASS_HASH_SQL="${PASS_HASH//\'/\\\'}"

mysql_q -e "UPDATE mailboxes SET password_hash='${PASS_HASH_SQL}' WHERE id=${MB_ID} LIMIT 1;"

log "INFO" "mail.passwd $EMAIL ok"
audit "cli" "mail.passwd" "$EMAIL" "ok" "hash updated"
echo "OK mailbox=$EMAIL password updated"
echo "PASSWORD=${PLAIN_PASS}"
exit 0
