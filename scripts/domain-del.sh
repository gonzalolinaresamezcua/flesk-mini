#!/usr/bin/env bash
# Flesk — baja de dominio: quita vhost, webmail, DKIM, zona, fila (buzones en cascada) y maildirs;
# el docroot va a var/backups salvo --keep-data (que conserva docroot y maildirs)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/rollback.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/dns.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/isolation.sh"

usage() {
  echo "Uso: flesk domain del|remove <dominio> [--keep-data]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dominio"; fi

DOMAIN_RAW="$1"
shift
KEEP_DATA=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-data) KEEP_DATA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

DOMAIN="$(valid_domain "$DOMAIN_RAW")" || die 2 "Dominio inválido: $DOMAIN_RAW"

VHOSTS_ROOT="${VHOSTS_ROOT:-/var/www/vhosts}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"
SITE_DIR="$VHOSTS_ROOT/$DOMAIN"
SYS_DIR="$VHOSTS_ROOT/system/$DOMAIN"
VHOST_FILE="$NGINX_ENABLED/${DOMAIN}.conf"

lock "domain:$DOMAIN"
trap 'unlock' EXIT

EXISTING_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' LIMIT 1;" 2>/dev/null || true)"

# Idempotente si no hay fila ni vhost ni dirs
if [[ -z "$EXISTING_ID" && ! -f "$VHOST_FILE" && ! -d "$SITE_DIR" ]]; then
  log "INFO" "domain.del $DOMAIN idempotente (no existe)"
  audit "cli" "domain.del" "$DOMAIN" "ok" "idempotent"
  echo "OK domain=$DOMAIN (no existía)"
  exit 0
fi

# Quitar vhost
if [[ -f "$VHOST_FILE" ]]; then
  backup_file "$VHOST_FILE"
  rm -f "$VHOST_FILE"
  log "INFO" "Eliminado vhost $VHOST_FILE"
fi

# Repositorios git desplegados (flesk git): parar y quitar sus servicios y filas (los archivos se van con el dominio)
for GID in $(mysql_q -e "SELECT id FROM git_repos WHERE domain='${DOMAIN}';" 2>>"$FRESK_LOG" || true); do
  [[ "$GID" =~ ^[0-9]+$ ]] || continue
  if [[ -f "/etc/systemd/system/flesk-git-$GID.service" ]]; then
    systemctl disable --now "flesk-git-$GID" >>"$FRESK_LOG" 2>&1 || true
    rm -f "/etc/systemd/system/flesk-git-$GID.service"; systemctl daemon-reload || true
  fi
  rm -f "$FRESK_ROOT/var/git/logs/$GID.log"
  mysql_q -e "DELETE FROM git_repos WHERE id=$GID;" 2>>"$FRESK_LOG" || true
  audit "cli" "git.remove" "$DOMAIN" "ok" "id=$GID (dominio eliminado)"
done

# Reglas de aplicaciones instaladas (flesk app install)
[[ -n "$DOMAIN" && -d "/etc/nginx/fresk-apps/$DOMAIN" ]] && rm -rf --one-file-system -- "/etc/nginx/fresk-apps/$DOMAIN"

if ! nginx -t 2>/tmp/fresk-nginx-t.err; then
  log "ERROR" "nginx -t falló tras quitar vhost"
  cat /tmp/fresk-nginx-t.err >&2 || true
  die 5 "nginx -t falló tras eliminar vhost"
fi
reload_service nginx

# Bases de datos del dominio (antes caían solo las filas por CASCADE y quedaban huérfanas en MariaDB)
if [[ -n "$EXISTING_ID" && "$KEEP_DATA" -eq 0 ]]; then
  while read -r _db; do
    [[ "$_db" =~ ^[a-z0-9_]{1,64}$ ]] || continue
    bash "$FRESK_ROOT/scripts/db-drop.sh" "$_db" --yes >/dev/null 2>&1 && log "INFO" "BD $_db eliminada" || log "WARN" "No se pudo eliminar la BD $_db"
  done < <(mysql_q -e "SELECT db_name FROM \`databases\` WHERE domain_id=${EXISTING_ID};" 2>/dev/null || true)
fi

# Cuentas SFTP del dominio (alias del usuario fk_<dominio>): se borran del sistema; las filas caen por CASCADE
if [[ -n "$EXISTING_ID" ]]; then
  while read -r _su; do
    [[ "$_su" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || continue
    case "$_su" in root|www-data|flesk|fresk|vmail|nobody) continue ;; esac
    if [[ "$(getent passwd "$_su" | cut -d: -f6)" == "$SITE_DIR" ]]; then
      usermod -L "$_su" 2>/dev/null || true
      pkill -f "^sshd(-session)?: ${_su}([ @]|$)" 2>/dev/null || true
      userdel -f "$_su" 2>/dev/null && log "INFO" "Usuario SFTP $_su eliminado" || log "WARN" "No se pudo eliminar el usuario SFTP $_su"
    fi
  done < <(mysql_q -e "SELECT system_user FROM sftp_users WHERE domain_id=${EXISTING_ID};" 2>/dev/null || true)
fi

# Borrar fila DB
if [[ -n "$EXISTING_ID" ]]; then
  mysql_q -e "DELETE FROM domains WHERE name='${DOMAIN}' LIMIT 1;" \
    || die 5 "No se pudo borrar fila domains para $DOMAIN"
  # Programación de copias del dominio (las copias ya hechas se conservan en /var/backups/flesk)
  mysql_q -e "DELETE FROM backup_schedules WHERE scope='domain_${DOMAIN}';" 2>/dev/null || true
  mysql_q -e "DELETE FROM stats_hits WHERE domain='${DOMAIN}'; DELETE FROM stats_state WHERE name='/var/www/vhosts/${DOMAIN}/logs/access.log';" 2>/dev/null || true
fi


# Fase 5: quitar zona BIND (dns_records caen por CASCADE al borrar domains)
if declare -F dns_remove_domain_zone >/dev/null 2>&1; then
  dns_remove_domain_zone "$DOMAIN" || log "WARN" "No se pudo limpiar zona DNS de $DOMAIN"
fi

# Webmail (vhost webmail.<dominio>) y clave DKIM
bash "$FRESK_ROOT/scripts/webmail-vhost.sh" remove "$DOMAIN" >/dev/null 2>&1 || log "WARN" "No se pudo quitar el webmail de $DOMAIN"
if [[ "$KEEP_DATA" -eq 0 ]]; then
  bash "$FRESK_ROOT/scripts/dkim.sh" del "$DOMAIN" >/dev/null 2>&1 || log "WARN" "No se pudo borrar la clave DKIM de $DOMAIN"
fi

# Buzones: las filas caen por CASCADE con el dominio; los maildirs se borran salvo --keep-data
VMAIL_HOME="${VMAIL_HOME:-/var/vmail}"
MAIL_DIR="$VMAIL_HOME/$DOMAIN"
if [[ -d "$MAIL_DIR" && -n "$DOMAIN" && "$MAIL_DIR" == "$VMAIL_HOME/"?* && "$(dirname "$MAIL_DIR")" == "$VMAIL_HOME" && ! -L "$MAIL_DIR" ]]; then
  if [[ "$KEEP_DATA" -eq 1 ]]; then
    log "INFO" "Conservando buzones en $MAIL_DIR (--keep-data)"
  else
    rm -rf --one-file-system -- "$MAIL_DIR"
    log "INFO" "Buzones de $DOMAIN eliminados ($MAIL_DIR)"
  fi
fi

# Datos
if [[ -d "$SITE_DIR" ]]; then
  if [[ "$KEEP_DATA" -eq 1 ]]; then
    log "INFO" "Conservando datos en $SITE_DIR (--keep-data)"
  else
    stamp="$(date '+%Y%m%d%H%M%S')"
    mkdir -p "$FRESK_BACKUPS"
    dest="$FRESK_BACKUPS/vhost_${DOMAIN}.${stamp}"
    mv "$SITE_DIR" "$dest"
    log "INFO" "Docroot movido a $dest"
    # system conf de referencia
    if [[ -d "$SYS_DIR" ]]; then
      mv "$SYS_DIR" "$FRESK_BACKUPS/vhost_system_${DOMAIN}.${stamp}" 2>/dev/null || rm -rf "$SYS_DIR"
    fi
  fi
else
  # Limpiar system aunque no haya site
  if [[ "$KEEP_DATA" -eq 0 && -d "$SYS_DIR" ]]; then
    rm -rf "$SYS_DIR"
  fi
fi

# Pool PHP-FPM, procesos, usuario y grupo fk_<dominio> (los datos ya se movieron a la copia)
iso_remove_domain "$DOMAIN" "$([[ "$KEEP_DATA" -eq 1 ]] && echo --keep-user)" || log "WARN" "No se pudo limpiar el aislamiento de $DOMAIN"

# Postfix/Dovecot: quitar SNI del dominio eliminado
bash "$FRESK_ROOT/scripts/mail-certs.sh" >/dev/null 2>&1 || true

# Con --keep-data, quitar solo conf de system si queremos limpieza ligera: se conserva
log "INFO" "domain.del $DOMAIN ok keep_data=$KEEP_DATA"
audit "cli" "domain.del" "$DOMAIN" "ok" "keep_data=$KEEP_DATA"
echo "OK domain=$DOMAIN removed keep_data=$KEEP_DATA"
exit 0
