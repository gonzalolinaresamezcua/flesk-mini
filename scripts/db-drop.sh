#!/usr/bin/env bash
# Flesk — baja de BD+usuario MariaDB (fase 6)
# Uso: flesk db del|drop <nombre_bd> --yes
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk db del|drop <nombre_bd> --yes" >&2
  echo "  Solo acepta nombres con prefijo db_ generados por Flesk." >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta nombre de base de datos"; fi

SITE_DB_RAW="$1"
shift
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

# Sanear y validar: solo a-z0-9_, debe empezar por db_
SITE_DB="$(printf '%s' "${SITE_DB_RAW,,}" | tr -cd 'a-z0-9_')"
if [[ -z "$SITE_DB" || "$SITE_DB" != "$SITE_DB_RAW" ]]; then
  die 2 "Nombre de BD inválido (solo a-z0-9_): $SITE_DB_RAW"
fi
if [[ ! "$SITE_DB" =~ ^db_[a-z0-9_]+$ ]]; then
  die 2 "Nombre rechazado: debe empezar por prefijo db_ de Flesk"
fi
if [[ ${#SITE_DB} -gt 64 ]]; then
  die 2 "Nombre de BD demasiado largo"
fi
if [[ "$YES" -ne 1 ]]; then
  die 2 "Confirmación requerida: añade --yes"
fi

lock "db:$SITE_DB"
trap 'unlock' EXIT

ROW="$(mysql_q -e "SELECT id, db_user, domain_id FROM \`databases\` WHERE db_name='${SITE_DB}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$ROW" ]]; then
  # Idempotente si tampoco existe en MariaDB
  DB_OK="$(mysql_admin_q -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${SITE_DB}' LIMIT 1;" 2>/dev/null || true)"
  if [[ -z "$DB_OK" ]]; then
    log "INFO" "db.del $SITE_DB idempotente (no existía)"
    echo "OK db=$SITE_DB (no existía)"
    exit 0
  fi
  die 4 "BD $SITE_DB existe en MariaDB pero no en panel (no se borra sin fila Flesk)"
fi

DB_ID="$(printf '%s' "$ROW" | awk '{print $1}')"
SITE_USER="$(printf '%s' "$ROW" | awk '{print $2}')"

if [[ ! "$SITE_USER" =~ ^user_[a-z0-9_]+$ ]]; then
  die 4 "Usuario asociado inválido ($SITE_USER); abortando por seguridad"
fi

# DROP DATABASE
mysql_admin_q -e "DROP DATABASE IF EXISTS \`${SITE_DB}\`;" \
  || die 5 "Fallo DROP DATABASE ${SITE_DB}"

for HOST in '127.0.0.1' 'localhost'; do
  mysql_admin_q -e "DROP USER IF EXISTS '${SITE_USER}'@'${HOST}';" \
    || log "WARN" "DROP USER ${SITE_USER}@${HOST} falló (puede no existir)"
done
mysql_admin_q -e "FLUSH PRIVILEGES;" || true

mysql_q -e "DELETE FROM \`databases\` WHERE id=${DB_ID} LIMIT 1;" \
  || die 5 "No se pudo borrar fila databases id=${DB_ID}"

log "INFO" "db.del $SITE_DB ok user=$SITE_USER"
audit "cli" "db.del" "$SITE_DB" "ok" "user=$SITE_USER"
echo "OK db=$SITE_DB user=$SITE_USER deleted"
exit 0
