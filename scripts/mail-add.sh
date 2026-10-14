#!/usr/bin/env bash
# Flesk — alta de buzón (fase 4)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/limits.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/rollback.sh"

usage() {
  echo "Uso: flesk mail add <user@dominio> [--quota 1024] [--password <claro> | --password-stdin]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dirección de buzón"; fi

EMAIL_RAW="$1"
shift
QUOTA_MB=1024
PLAIN_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quota)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --quota"
      QUOTA_MB="$2"
      shift 2
      ;;
    --password|--pass)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --password"
      PLAIN_PASS="$2"
      shift 2
      ;;
    --password-stdin)
      # Lee la contraseña de la primera línea de stdin (no queda en argv/ps)
      IFS= read -r PLAIN_PASS || true
      [[ -n "$PLAIN_PASS" ]] || die 2 "Contraseña vacía en stdin"
      shift
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

if [[ ! "$QUOTA_MB" =~ ^[0-9]+$ ]] || [[ "$QUOTA_MB" -lt 1 ]] || [[ "$QUOTA_MB" -gt 1048576 ]]; then
  die 2 "Cuota inválida: $QUOTA_MB (MB)"
fi

PARSED="$(parse_email "$EMAIL_RAW")" || die 2 "Email inválido: $EMAIL_RAW"
LOCAL_PART="${PARSED%% *}"
DOMAIN="${PARSED#* }"
EMAIL="${LOCAL_PART}@${DOMAIN}"

VMAIL_HOME="${VMAIL_HOME:-/var/vmail}"
# Ruta relativa a virtual_mailbox_base (/var/vmail)
MAILDIR_REL="${DOMAIN}/${LOCAL_PART}/"
MAILDIR_ABS="${VMAIL_HOME}/${DOMAIN}/${LOCAL_PART}"

lock "mail:$EMAIL"
trap 'unlock' EXIT
rb_reset

DOMAIN_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' AND status='active' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$DOMAIN_ID" ]]; then
  die 3 "Dominio no existe o no está active: $DOMAIN (flesk domain add $DOMAIN)"
fi

EXISTING="$(mysql_q -e "SELECT id FROM mailboxes WHERE domain_id=${DOMAIN_ID} AND local_part='${LOCAL_PART}' LIMIT 1;" 2>/dev/null || true)"
[[ -z "$EXISTING" ]] && mini_check mailboxes "cuenta de correo" "mail account"   # Flesk Mini
if [[ -n "$EXISTING" ]]; then
  if [[ -d "$MAILDIR_ABS" ]]; then
    log "INFO" "mail.add $EMAIL idempotente (ya activo)"
    audit "cli" "mail.add" "$EMAIL" "ok" "idempotent"
    echo "OK mailbox=$EMAIL (ya existía)"
    exit 0
  fi
  die 4 "Buzón $EMAIL existe en DB pero falta Maildir $MAILDIR_ABS"
fi

if [[ -z "$PLAIN_PASS" ]]; then
  PLAIN_PASS="$(gen_password)"
fi
PASS_HASH="$(hash_mailbox_password "$PLAIN_PASS")"
# Escapar comilla simple para SQL
PASS_HASH_SQL="${PASS_HASH//\'/\\\'}"

mkdir -p "$(dirname "$MAILDIR_ABS")"
ensure_maildir "$MAILDIR_ABS"
rb_push "rm -rf $(printf '%q' "$MAILDIR_ABS")"

if ! mysql_q -e "INSERT INTO mailboxes (domain_id, local_part, password_hash, quota_mb, maildir, active)
  VALUES (${DOMAIN_ID}, '${LOCAL_PART}', '${PASS_HASH_SQL}', ${QUOTA_MB}, '${MAILDIR_REL}', 1);"; then
  rb_run
  audit "cli" "mail.add" "$EMAIL" "fail" "mysql insert"
  die 6 "Fallo al insertar buzón; rollback ejecutado"
fi
rb_push "mysql_q -e \"DELETE FROM mailboxes WHERE domain_id=${DOMAIN_ID} AND local_part='${LOCAL_PART}' LIMIT 1;\""

rb_reset
log "INFO" "mail.add $EMAIL ok maildir=$MAILDIR_ABS quota=${QUOTA_MB}M"
audit "cli" "mail.add" "$EMAIL" "ok" "maildir+db"
echo "OK mailbox=$EMAIL maildir=$MAILDIR_ABS"
# Contraseña en claro: una sola vez por stdout, nunca al log
echo "PASSWORD=${PLAIN_PASS}"
exit 0
