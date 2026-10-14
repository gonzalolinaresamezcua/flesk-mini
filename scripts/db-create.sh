#!/usr/bin/env bash
# Flesk — alta de BD+usuario MariaDB por dominio (fase 6)
# Uso: flesk db add|create <dominio> [--name auto|<base>] [--password <claro>]
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/limits.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/rollback.sh"

usage() {
  echo "Uso: flesk db add|create <dominio> [--name auto|<base>] [--password <claro>]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dominio"; fi

DOMAIN_RAW="$1"
shift
NAME_OPT="auto"
PLAIN_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --name"
      NAME_OPT="$2"
      shift 2
      ;;
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

DOMAIN="$(valid_domain "$DOMAIN_RAW")" || die 2 "Dominio inválido: $DOMAIN_RAW"

# Base alfanumérica: ejemplo.com → ejemplocom
if [[ "$NAME_OPT" == "auto" || -z "$NAME_OPT" ]]; then
  BASE="$(printf '%s' "$DOMAIN" | tr -cd 'a-z0-9')"
else
  BASE="$(printf '%s' "${NAME_OPT,,}" | tr -cd 'a-z0-9_')"
  BASE="${BASE#_}"
fi
[[ -n "$BASE" ]] || die 2 "No se pudo derivar nombre de BD desde dominio/base"
# Rechazar metacaracteres ya filtrados; longitud mínima
if [[ ! "$BASE" =~ ^[a-z0-9_]+$ ]]; then
  die 2 "Nombre base inválido (solo a-z0-9_)"
fi

# db_ + base truncado a 32; user_ + base truncado a 16 (límite planning)
pick_unique_names() {
  local base="$1"
  local suffix="" i=0 cand_db cand_user exists
  while true; do
    if [[ $i -eq 0 ]]; then
      suffix=""
    else
      suffix="_${i}"
    fi
    cand_db="db_${base}${suffix}"
    cand_db="${cand_db:0:32}"
    cand_user="user_${base}${suffix}"
    cand_user="${cand_user:0:16}"
    # Validar identificadores finales
    if [[ ! "$cand_db" =~ ^[a-z0-9_]+$ ]] || [[ ! "$cand_user" =~ ^[a-z0-9_]+$ ]]; then
      die 2 "Identificador generado inválido"
    fi
    exists="$(mysql_q -e "SELECT id FROM \`databases\` WHERE db_name='${cand_db}' OR db_user='${cand_user}' LIMIT 1;" 2>/dev/null || true)"
    if [[ -z "$exists" ]]; then
      # También comprobar en MariaDB real
      local db_exists user_exists
      db_exists="$(mysql_admin_q -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${cand_db}' LIMIT 1;" 2>/dev/null || true)"
      user_exists="$(mysql_admin_q -e "SELECT user FROM mysql.user WHERE user='${cand_user}' AND host IN ('127.0.0.1','localhost') LIMIT 1;" 2>/dev/null || true)"
      if [[ -z "$db_exists" && -z "$user_exists" ]]; then
        printf '%s %s' "$cand_db" "$cand_user"
        return 0
      fi
    fi
    i=$((i + 1))
    if [[ $i -gt 99 ]]; then
      die 4 "No hay nombre libre para BD/usuario (colisión)"
    fi
  done
}

lock "db:$DOMAIN"
trap 'unlock' EXIT
rb_reset

DOMAIN_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' AND status='active' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$DOMAIN_ID" ]]; then
  die 3 "Dominio no existe o no está active: $DOMAIN (flesk domain add $DOMAIN)"
fi

# Idempotencia: si el dominio ya tiene exactamente una BD con nombres derivados y existen en MariaDB → OK
EXISTING_ROW="$(mysql_q -e "SELECT db_name, db_user FROM \`databases\` WHERE domain_id=${DOMAIN_ID} ORDER BY id LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$EXISTING_ROW" || "$NAME_OPT" != "auto" ]]; then mini_check databases "base de datos" "database"; fi   # Flesk Mini
if [[ -n "$EXISTING_ROW" && "$NAME_OPT" == "auto" ]]; then
  EXIST_DB="$(printf '%s' "$EXISTING_ROW" | awk '{print $1}')"
  EXIST_USER="$(printf '%s' "$EXISTING_ROW" | awk '{print $2}')"
  DB_OK="$(mysql_admin_q -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${EXIST_DB}' LIMIT 1;" 2>/dev/null || true)"
  USER_OK="$(mysql_admin_q -e "SELECT user FROM mysql.user WHERE user='${EXIST_USER}' AND host IN ('127.0.0.1','localhost') LIMIT 1;" 2>/dev/null || true)"
  if [[ -n "$DB_OK" && -n "$USER_OK" ]]; then
    log "INFO" "db.add $DOMAIN idempotente db=$EXIST_DB user=$EXIST_USER"
    audit "cli" "db.add" "$DOMAIN" "ok" "idempotent $EXIST_DB"
    echo "OK domain=$DOMAIN db=$EXIST_DB user=$EXIST_USER (ya existía)"
    exit 0
  fi
  die 4 "Dominio $DOMAIN ya tiene fila databases ($EXIST_DB) inconsistente con MariaDB"
fi

NAMES="$(pick_unique_names "$BASE")"
SITE_DB="${NAMES%% *}"
SITE_USER="${NAMES#* }"

if [[ -z "$PLAIN_PASS" ]]; then
  PLAIN_PASS="$(gen_password)"
fi
# Escape SQL single quotes
PASS_SQL="${PLAIN_PASS//\'/\'\'}"

# Crear BD
if ! mysql_admin_q -e "CREATE DATABASE \`${SITE_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
  rb_run
  audit "cli" "db.add" "$DOMAIN" "fail" "CREATE DATABASE"
  die 5 "Fallo CREATE DATABASE ${SITE_DB}"
fi
rb_push "mysql_admin_q -e \"DROP DATABASE IF EXISTS \\\`${SITE_DB}\\\`;\""

# Usuario en 127.0.0.1 y localhost (PHP tcp vs socket)
for HOST in '127.0.0.1' 'localhost'; do
  if ! mysql_admin_q -e "CREATE USER '${SITE_USER}'@'${HOST}' IDENTIFIED BY '${PASS_SQL}';"; then
    rb_run
    audit "cli" "db.add" "$DOMAIN" "fail" "CREATE USER @${HOST}"
    die 5 "Fallo CREATE USER ${SITE_USER}@${HOST}"
  fi
  rb_push "mysql_admin_q -e \"DROP USER IF EXISTS '${SITE_USER}'@'${HOST}';\""
  # Privilegios explícitos (fresk_admin no tiene ALL global; planning lo prohíbe)
  if ! mysql_admin_q -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, REFERENCES, INDEX, ALTER,
    CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW,
    CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER
    ON \`${SITE_DB}\`.* TO '${SITE_USER}'@'${HOST}';"; then
    rb_run
    audit "cli" "db.add" "$DOMAIN" "fail" "GRANT @${HOST}"
    die 5 "Fallo GRANT sobre ${SITE_DB} a ${SITE_USER}@${HOST}"
  fi
done

if ! mysql_admin_q -e "FLUSH PRIVILEGES;"; then
  log "WARN" "FLUSH PRIVILEGES falló (puede ser irrelevante)"
fi

if ! mysql_q -e "INSERT INTO \`databases\` (domain_id, db_name, db_user) VALUES (${DOMAIN_ID}, '${SITE_DB}', '${SITE_USER}');"; then
  rb_run
  audit "cli" "db.add" "$DOMAIN" "fail" "mysql insert"
  die 6 "Fallo al insertar fila databases; rollback ejecutado"
fi

rb_reset
log "INFO" "db.add $DOMAIN ok db=$SITE_DB user=$SITE_USER"
audit "cli" "db.add" "$DOMAIN" "ok" "db=$SITE_DB user=$SITE_USER"
echo "OK domain=$DOMAIN db=$SITE_DB user=$SITE_USER host=127.0.0.1"
echo "PASSWORD=${PLAIN_PASS}"
exit 0
