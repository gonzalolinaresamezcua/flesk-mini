#!/usr/bin/env bash
# Flesk — credencial efímera de MariaDB para abrir Adminer sin contraseña (SSO del panel).
# Uso: flesk db login <nombre_bd>
#   Crea fks_<expira_epoch>_<aleatorio>@localhost con privilegios SOLO sobre <nombre_bd>,
#   contraseña aleatoria que solo se entrega por stdout al proceso del panel (nunca al navegador
#   ni a disco). Caduca a las FLESK_SGBD_TTL s (por defecto 2 h); "flesk db logout --expired" la borra.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed

[[ $# -eq 1 ]] || die 2 "Uso: flesk db login <nombre_bd>"
SITE_DB_RAW="$1"
SITE_DB="$(printf '%s' "${SITE_DB_RAW,,}" | tr -cd 'a-z0-9_')"
if [[ -z "$SITE_DB" || "$SITE_DB" != "$SITE_DB_RAW" || ! "$SITE_DB" =~ ^db_[a-z0-9_]+$ || ${#SITE_DB} -gt 64 ]]; then
  die 2 "Nombre de BD inválido: $SITE_DB_RAW"
fi
ROW="$(mysql_q -e "SELECT db_name FROM \`databases\` WHERE db_name='${SITE_DB}' LIMIT 1;" || true)"
[[ "$ROW" == "$SITE_DB" ]] || die 3 "Base de datos no registrada en el panel: $SITE_DB"

# Limpieza oportunista de credenciales caducadas
bash "$FRESK_ROOT/scripts/db-logout.sh" --expired >&2 || log "WARN" "purga de credenciales SGBD falló"

TTL="${FLESK_SGBD_TTL:-7200}"
[[ "$TTL" =~ ^[0-9]+$ && "$TTL" -ge 60 && "$TTL" -le 43200 ]] || TTL=7200
EXP=$(( $(date +%s) + TTL ))
RND="$(tr -dc 'a-f0-9' </dev/urandom | head -c 10 || true)"
EUSER="fks_${EXP}_${RND}"
EPASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
[[ ${#RND} -eq 10 && ${#EPASS} -eq 32 ]] || die 5 "No se pudo generar la credencial"
DB_ESC="${SITE_DB//_/\\_}"

# SQL por stdin (printf es builtin): la contraseña no aparece en argv/ps
if ! printf "CREATE USER '%s'@'localhost' IDENTIFIED BY '%s' WITH MAX_USER_CONNECTIONS 10;\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';\n" \
    "$EUSER" "$EPASS" "$DB_ESC" "$EUSER" | mysql_admin_q; then
  mysql_admin_q -e "DROP USER IF EXISTS '${EUSER}'@'localhost';" || true
  die 5 "No se pudo crear la credencial efímera"
fi
log "INFO" "db.login $SITE_DB user=$EUSER ttl=${TTL}s"
audit "cli" "db.login" "$SITE_DB" "ok" "user=$EUSER ttl=${TTL}s"
echo "USER=${EUSER}"
echo "EXPIRES=${EXP}"
echo "PASSWORD=${EPASS}"
exit 0
