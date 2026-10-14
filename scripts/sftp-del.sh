#!/usr/bin/env bash
# Flesk — baja de usuario SFTP (fase 7). No borra httpdocs.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk sftp del <usuario> [--yes]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta usuario SFTP"; fi

USER_RAW="$1"
shift
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

if [[ ! "$USER_RAW" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  die 2 "Usuario inválido: $USER_RAW"
fi
if [[ "$USER_RAW" =~ [\;\'\`\$[:space:]] ]]; then
  die 2 "Usuario inválido (caracteres prohibidos): $USER_RAW"
fi
USERNAME="$USER_RAW"

if [[ "$YES" -ne 1 ]]; then
  die 2 "Confirmación requerida: añade --yes (flesk sftp del $USERNAME --yes)"
fi

lock "sftp:$USERNAME"
trap 'unlock' EXIT

ROW="$(mysql_q -e "SELECT id, system_user, domain_id FROM sftp_users WHERE username='${USERNAME}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$ROW" ]]; then
  log "INFO" "sftp.del $USERNAME idempotente (no existía en panel)"
  echo "OK sftp_user=$USERNAME (no existía)"
  exit 0
fi

SFTP_ID="$(printf '%s' "$ROW" | awk '{print $1}')"
SYS_USER="$(printf '%s' "$ROW" | awk '{print $2}')"
DOMAIN_ID="$(printf '%s' "$ROW" | awk '{print $3}')"

# Seguridad: solo borrar cuentas registradas en sftp_users
case "$SYS_USER" in
  fk_*|flesk|root|www-data|ubuntu|fresk|vmail|nobody)
    die 3 "Negado: system_user protegido $SYS_USER"
    ;;
esac

DOMAIN_NAME="$(mysql_q -e "SELECT name FROM domains WHERE id=${DOMAIN_ID} LIMIT 1;" 2>/dev/null || true)"

# Quitar fila primero (fuente de verdad del panel)
mysql_q -e "DELETE FROM sftp_users WHERE id=${SFTP_ID} LIMIT 1;"

if id "$SYS_USER" >/dev/null 2>&1; then
  # Bloquear, matar sesiones SFTP residuales y eliminar cuenta (sin -r: no toca el vhost)
  usermod -L "$SYS_USER" 2>/dev/null || true
  # Comparte UID con el usuario del pool PHP: no usar pkill -u (mataría PHP-FPM); solo sus sesiones SSH
  pkill -f "^sshd(-session)?: ${SYS_USER}([ @]|$)" 2>/dev/null || true
  sleep 0.3
  # userdel -f: fuerza aunque queden procesos/at; sin -r → no borra httpdocs
  if ! userdel -f "$SYS_USER" 2>/tmp/fresk-sftp-userdel.err; then
    log "WARN" "userdel -f $SYS_USER falló; cuenta queda bloqueada (usermod -L). $(tr '\n' ' ' </tmp/fresk-sftp-userdel.err 2>/dev/null || true)"
  fi
fi

# rc3: httpdocs sigue siendo del usuario del dominio (fk_<dominio>); solo se reajustan permisos del árbol
if [[ -n "$DOMAIN_NAME" && -d "${VHOSTS_ROOT:-/var/www/vhosts}/${DOMAIN_NAME}" ]]; then
  # shellcheck disable=SC1091
  source "$FRESK_ROOT/lib/isolation.sh"
  if iso_is_isolated "$DOMAIN_NAME"; then iso_fix_perms "$DOMAIN_NAME"; fi
fi

log "INFO" "sftp.del $USERNAME ok system_user=$SYS_USER domain=${DOMAIN_NAME:-?} (httpdocs conservado)"
audit "cli" "sftp.del" "$USERNAME" "ok" "system_user=$SYS_USER"
echo "OK sftp_user=$USERNAME deleted"
exit 0
