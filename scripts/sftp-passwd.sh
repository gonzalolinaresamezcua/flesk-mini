#!/usr/bin/env bash
# Flesk — regenerar contraseña SFTP (fase 7)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk sftp passwd <usuario> [--password <claro>]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta usuario SFTP"; fi

USER_RAW="$1"
shift
PLAIN_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password|--pass)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --password"
      PLAIN_PASS="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

# Validación estricta (mismo patrón que sftp-add)
if [[ ! "$USER_RAW" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  die 2 "Usuario inválido: $USER_RAW"
fi
if [[ "$USER_RAW" =~ [\;\'\`\$[:space:]] ]]; then
  die 2 "Usuario inválido (caracteres prohibidos): $USER_RAW"
fi
USERNAME="$USER_RAW"

lock "sftp:$USERNAME"
trap 'unlock' EXIT

ROW="$(mysql_q -e "SELECT system_user FROM sftp_users WHERE username='${USERNAME}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$ROW" ]]; then
  die 3 "Usuario SFTP no encontrado en panel: $USERNAME"
fi
SYS_USER="$ROW"

if ! id "$SYS_USER" >/dev/null 2>&1; then
  die 3 "Usuario de sistema ausente: $SYS_USER (fila huérfana en sftp_users)"
fi

if [[ -z "$PLAIN_PASS" ]]; then
  PLAIN_PASS="$(gen_password)"
fi

# chpasswd no escribe la contraseña en logs de flesk
if ! printf '%s:%s\n' "$SYS_USER" "$PLAIN_PASS" | chpasswd; then
  die 6 "No se pudo actualizar la contraseña de $SYS_USER"
fi
# Desbloquear por si estaba L
usermod -U "$SYS_USER" 2>/dev/null || true

log "INFO" "sftp.passwd $USERNAME ok system_user=$SYS_USER"
audit "cli" "sftp.passwd" "$USERNAME" "ok" "password updated"
echo "OK sftp_user=$USERNAME password updated"
echo "PASSWORD=${PLAIN_PASS}"
exit 0
