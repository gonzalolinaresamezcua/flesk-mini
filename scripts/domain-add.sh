#!/usr/bin/env bash
# Flesk — alta de dominio (fase 2): dirs, vhost HTTP, fila domains
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/limits.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/rollback.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/isolation.sh"

usage() {
  echo "Uso: flesk domain add <dominio> [--php 8.3|8.5] [--ip auto|<ipv4>]" >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dominio"; fi

DOMAIN_RAW="$1"
shift
PHP_VER="${PHP_VERSION:-8.3}"
IP_MODE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --php"
      PHP_VER="$2"
      shift 2
      ;;
    --ip)
      [[ $# -ge 2 ]] || die 2 "Falta valor para --ip"
      IP_MODE="$2"
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

if [[ ! "$PHP_VER" =~ ^[0-9]+\.[0-9]+$ ]]; then
  die 2 "Versión PHP inválida: $PHP_VER"
fi

DOMAIN="$(valid_domain "$DOMAIN_RAW")" || die 2 "Dominio inválido: $DOMAIN_RAW"

VHOSTS_ROOT="${VHOSTS_ROOT:-/var/www/vhosts}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"
WEB_USER="${WEB_USER:-www-data}"
PUBLIC_IP="${PUBLIC_IP:-}"

# Pool PHP-FPM propio del dominio (usuario fk_<dominio>, socket solo para nginx)
[[ -d "/etc/php/$PHP_VER/fpm/pool.d" ]] || die 3 "PHP-FPM $PHP_VER no está instalado"
PHP_FPM_SOCK="$(iso_sock "$DOMAIN")"

DOCROOT="$VHOSTS_ROOT/$DOMAIN/httpdocs"
LOGDIR="$VHOSTS_ROOT/$DOMAIN/logs"
TMPDIR_D="$VHOSTS_ROOT/$DOMAIN/tmp"
SYS_CONF="$VHOSTS_ROOT/system/$DOMAIN/conf"
SYS_LOGS="$VHOSTS_ROOT/system/$DOMAIN/logs"
VHOST_FILE="$NGINX_ENABLED/${DOMAIN}.conf"
REF_VHOST="$SYS_CONF/nginx.conf"
WELCOME_SRC="$FRESK_ROOT/templates/index.html"

IPV4=""
if [[ "$IP_MODE" == "auto" ]]; then
  IPV4="$PUBLIC_IP"
elif [[ "$IP_MODE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IPV4="$IP_MODE"
else
  die 2 "IP inválida: $IP_MODE (usa auto o IPv4)"
fi

lock "domain:$DOMAIN"
trap 'unlock' EXIT
rb_reset

# Idempotencia: si DB + vhost + docroot coinciden → OK
EXISTING_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' LIMIT 1;" 2>/dev/null || true)"
[[ -z "$EXISTING_ID" ]] && mini_check domains "dominio" "domain"   # Flesk Mini
if [[ -n "$EXISTING_ID" ]]; then
  if [[ -f "$VHOST_FILE" && -d "$DOCROOT" ]]; then
    log "INFO" "domain.add $DOMAIN idempotente (ya activo)"
    audit "cli" "domain.add" "$DOMAIN" "ok" "idempotent"
    echo "OK domain=$DOMAIN (ya existía)"
    exit 0
  fi
  die 4 "Dominio $DOMAIN existe en DB pero falta vhost/docroot. Ejecuta: flesk domain del $DOMAIN y vuelve a añadir."
fi

if [[ -f "$VHOST_FILE" ]]; then
  die 4 "Conflicto: ya existe vhost $VHOST_FILE sin fila en DB"
fi


if [[ ! -d "$VHOSTS_ROOT/$DOMAIN" ]]; then
  mkdir -p "$DOCROOT" "$LOGDIR" "$TMPDIR_D"
  rb_push "rm -rf $(printf '%q' "$VHOSTS_ROOT/$DOMAIN")"
else
  mkdir -p "$DOCROOT" "$LOGDIR" "$TMPDIR_D"
fi

if [[ ! -d "$VHOSTS_ROOT/system/$DOMAIN" ]]; then
  mkdir -p "$SYS_CONF" "$SYS_LOGS"
  rb_push "rm -rf $(printf '%q' "$VHOSTS_ROOT/system/$DOMAIN")"
else
  mkdir -p "$SYS_CONF" "$SYS_LOGS"
fi

# Aislamiento (rc3): usuario/grupo fk_<dominio>; raíz del dominio root:root 755 (chroot SFTP);
# httpdocs <u>:<u> 2770 (solo el sitio, nginx y el panel); tmp/sesiones propios; logs root:<u> 750.
ISO_PHP_VER="$PHP_VER"
SITE_USER="$(iso_ensure_user "$DOMAIN")"
rb_push "iso_remove_domain $(printf '%q' "$DOMAIN")"
iso_fix_perms "$DOMAIN"

# Página de bienvenida solo si httpdocs vacío
if [[ -z "$(ls -A "$DOCROOT" 2>/dev/null || true)" ]]; then
  if [[ -f "$WELCOME_SRC" ]]; then
    cp "$WELCOME_SRC" "$DOCROOT/index.html"
    chown "${SITE_USER}:${SITE_USER}" "$DOCROOT/index.html"; chmod 664 "$DOCROOT/index.html"
    # Favicon FLESK (3 cubos) junto a la bienvenida
    for fav in favicon.ico favicon.svg favicon-32.png apple-touch-icon.png; do
      if [[ -f "$FRESK_ROOT/web/assets/img/$fav" ]]; then
        cp "$FRESK_ROOT/web/assets/img/$fav" "$DOCROOT/$fav"
        chown "${SITE_USER}:${SITE_USER}" "$DOCROOT/$fav"
        chmod 664 "$DOCROOT/$fav"
      fi
    done
  fi
fi

# Pool PHP-FPM del dominio (php-fpm -t antes de recargar; se restaura si falla)
iso_write_pool "$DOMAIN"
iso_reload_fpm "$DOMAIN"

# Render vhost
TMP_VHOST="$(mktemp "$FRESK_RUN/vhost.XXXXXX")"
rb_push "rm -f $(printf '%q' "$TMP_VHOST")"
render_template \
  "$FRESK_ROOT/templates/nginx-vhost.conf" \
  "$TMP_VHOST" \
  "DOMAIN=$DOMAIN" \
  "PHP_FPM_SOCK=$PHP_FPM_SOCK"

# Instalar vhost (backup si existiera)
backup_file "$VHOST_FILE"
atomic_install "$TMP_VHOST" "$VHOST_FILE" 644 root:root
rb_push "rm -f $(printf '%q' "$VHOST_FILE")"
cp -a "$VHOST_FILE" "$REF_VHOST"
chown root:root "$REF_VHOST"
chmod 644 "$REF_VHOST"

# nginx -t antes de commit DB
if ! nginx -t 2>/tmp/fresk-nginx-t.err; then
  log "ERROR" "nginx -t falló tras escribir $VHOST_FILE"
  cat /tmp/fresk-nginx-t.err >&2 || true
  rb_run
  audit "cli" "domain.add" "$DOMAIN" "fail" "nginx -t"
  die 6 "nginx -t falló; rollback ejecutado"
fi

reload_service nginx

# Insertar fila (dominio validado → seguro en SQL)
IPV4_SQL="NULL"
if [[ -n "$IPV4" ]]; then
  IPV4_SQL="'${IPV4}'"
fi
if ! mysql_q -e "INSERT INTO domains (name, php_version, ipv4, docroot, status) VALUES ('${DOMAIN}', '${PHP_VER}', ${IPV4_SQL}, '${DOCROOT}', 'active');"; then
  log "ERROR" "INSERT domains falló para $DOMAIN"
  rb_run
  # Tras rollback del vhost, recargar nginx
  if nginx -t >/dev/null 2>&1; then reload_service nginx; fi
  audit "cli" "domain.add" "$DOMAIN" "fail" "mysql insert"
  die 6 "Fallo al insertar en DB; rollback ejecutado"
fi
rb_push "mysql_q -e \"DELETE FROM domains WHERE name='${DOMAIN}' LIMIT 1;\""

# Si llegamos aquí, éxito: vaciar pila (no queremos deshacer)
rb_reset


# Fase 5: zona DNS mínima (no falla el alta de dominio si BIND falla)
if [[ -f "$FRESK_ROOT/scripts/dns-init.sh" ]]; then
  if bash "$FRESK_ROOT/scripts/dns-init.sh" "$DOMAIN"; then
    log "INFO" "dns-init ok para $DOMAIN"
  else
    log "WARN" "dns-init falló para $DOMAIN — dominio creado; zona pendiente (flesk dns init $DOMAIN)"
  fi
fi

# Webmail (Roundcube) en webmail.<dominio>
bash "$FRESK_ROOT/scripts/webmail-vhost.sh" vhost "$DOMAIN" >/dev/null 2>&1 || log "WARN" "webmail vhost pendiente para $DOMAIN"
# Certificado de webmail.<dominio> si su A ya apunta aquí (si no, queda aviso en el log y en Correo/SSL)
if WM_OUT="$(bash "$FRESK_ROOT/scripts/webmail-vhost.sh" ssl "$DOMAIN" 2>&1)"; then
  log "INFO" "webmail ssl $DOMAIN: ${WM_OUT##*$'\n'}"
else
  log "WARN" "webmail ssl $DOMAIN pendiente: ${WM_OUT##*$'\n'}"
fi

log "INFO" "domain.add $DOMAIN ok docroot=$DOCROOT vhost=$VHOST_FILE php=$PHP_VER user=$SITE_USER pool=$(iso_sock "$DOMAIN")"
audit "cli" "domain.add" "$DOMAIN" "ok" "vhost+dirs+db"
echo "OK domain=$DOMAIN docroot=$DOCROOT user=$SITE_USER"
exit 0
