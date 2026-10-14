#!/usr/bin/env bash
# Flesk — volcado completo de una BD de sitio a stdout (gzip), sin ficheros temporales.
# Uso: flesk db dump <nombre_bd>
# Solo bases registradas en el panel (tabla databases) y con prefijo db_.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed

[[ $# -eq 1 ]] || die 2 "Uso: flesk db dump <nombre_bd>"
SITE_DB_RAW="$1"
SITE_DB="$(printf '%s' "${SITE_DB_RAW,,}" | tr -cd 'a-z0-9_')"
if [[ -z "$SITE_DB" || "$SITE_DB" != "$SITE_DB_RAW" || ! "$SITE_DB" =~ ^db_[a-z0-9_]+$ || ${#SITE_DB} -gt 64 ]]; then
  die 2 "Nombre de BD inválido: $SITE_DB_RAW"
fi
ROW="$(mysql_q -e "SELECT db_name FROM \`databases\` WHERE db_name='${SITE_DB}' LIMIT 1;" || true)"
[[ "$ROW" == "$SITE_DB" ]] || die 3 "Base de datos no registrada en el panel: $SITE_DB"
EXISTS="$(mysql_admin_q -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${SITE_DB}' LIMIT 1;" || true)"
[[ "$EXISTS" == "$SITE_DB" ]] || die 3 "La base $SITE_DB no existe en MariaDB"

DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump || true)"
[[ -n "$DUMP_BIN" ]] || die 3 "Falta mariadb-dump/mysqldump"

pass_file="${DB_ADMIN_PASS_FILE:-$FRESK_ROOT/var/.dbadminpass}"
[[ -f "$pass_file" ]] || die 3 "Falta contraseña DB admin"
# Sin ficheros intermedios: mysqldump | gzip directo a stdout (el panel lo reenvía en streaming)
umask 077
MYSQL_PWD="$(<"$pass_file")" "$DUMP_BIN" -h "${DB_HOST:-127.0.0.1}" -u "${DB_ADMIN_USER:-fresk_admin}" \
  --single-transaction --quick --routines --triggers --events --hex-blob \
  --default-character-set=utf8mb4 --no-tablespaces "$SITE_DB" | gzip -c -6 && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  audit "cli" "db.dump" "$SITE_DB" "ok" ""
else
  audit "cli" "db.dump" "$SITE_DB" "fail" "rc=$rc"
fi
exit $rc
