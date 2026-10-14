#!/usr/bin/env bash
# Flesk — cambio de contraseña de usuario de BD de sitio (fase 6)
# Uso: flesk db passwd <nombre_bd> [--password <claro>]
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk db passwd <nombre_bd> [--password <claro>]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta nombre de base de datos"; fi

SITE_DB_RAW="$1"
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

SITE_DB="$(printf '%s' "${SITE_DB_RAW,,}" | tr -cd 'a-z0-9_')"
if [[ -z "$SITE_DB" || "$SITE_DB" != "$SITE_DB_RAW" ]]; then
  die 2 "Nombre de BD inválido: $SITE_DB_RAW"
fi
if [[ ! "$SITE_DB" =~ ^db_[a-z0-9_]+$ ]]; then
  die 2 "Nombre rechazado: debe empezar por prefijo db_ de Flesk"
fi

lock "db:$SITE_DB"
trap 'unlock' EXIT

ROW="$(mysql_q -e "SELECT db_user FROM \`databases\` WHERE db_name='${SITE_DB}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$ROW" ]]; then
  die 3 "Base de datos no registrada en el panel: $SITE_DB"
fi
SITE_USER="$(printf '%s' "$ROW" | awk '{print $1}')"
if [[ ! "$SITE_USER" =~ ^user_[a-z0-9_]+$ ]]; then
  die 4 "Usuario asociado inválido ($SITE_USER)"
fi

if [[ -z "$PLAIN_PASS" ]]; then
  PLAIN_PASS="$(gen_password)"
fi
PASS_SQL="${PLAIN_PASS//\'/\'\'}"

for HOST in '127.0.0.1' 'localhost'; do
  # ALTER USER es el camino moderno; si el host no existe, CREATE no aplica aquí
  if ! mysql_admin_q -e "ALTER USER '${SITE_USER}'@'${HOST}' IDENTIFIED BY '${PASS_SQL}';" 2>/dev/null; then
    # Puede no existir uno de los dos hosts
    log "WARN" "ALTER USER ${SITE_USER}@${HOST} no aplicado (¿host inexistente?)"
  fi
done
mysql_admin_q -e "FLUSH PRIVILEGES;" || true

log "INFO" "db.passwd $SITE_DB ok user=$SITE_USER"
audit "cli" "db.passwd" "$SITE_DB" "ok" "user=$SITE_USER"
echo "OK db=$SITE_DB user=$SITE_USER password updated"
echo "PASSWORD=${PLAIN_PASS}"
exit 0
