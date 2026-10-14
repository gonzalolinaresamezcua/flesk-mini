#!/usr/bin/env bash
# Flesk — alta de usuario SFTP chroot (fase 7)
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
  echo "Uso: flesk sftp add <dominio> <usuario> [--password <claro>]" >&2
}

# Usuarios de sistema que nunca se reutilizan ni se crean como SFTP
sftp_reserved_user() {
  local u="$1"
  case "$u" in
    fk_*|flesk|root|www-data|ubuntu|fresk|vmail|nobody|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|backup|list|irc|gnats|sshd|mysql|postfix|dovecot|dovenull|bind|named|nginx|systemd-*|messagebus|_apt|syslog|landscape|pollinate|tcpdump|fwupd-refresh|uuidd|dnsmasq|Debian-exim|Debian-snmp)
      return 0 ;;
  esac
  return 1
}

valid_sftp_username() {
  local u="${1:-}"
  if [[ -z "$u" || ${#u} -gt 32 ]]; then return 1; fi
  if [[ ! "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then return 1; fi
  if [[ "$u" =~ [\;\'\`\$[:space:]\"\\] ]]; then return 1; fi
  if sftp_reserved_user "$u"; then return 1; fi
  printf '%s' "$u"
  return 0
}

ensure_sftponly_group() {
  if ! getent group sftponly >/dev/null 2>&1; then
    groupadd --system sftponly
    log "INFO" "Grupo sftponly creado"
  fi
}

# Ajusta ownership chroot-safe del árbol del dominio (rc3: aislamiento por dominio).
# httpdocs sigue siendo del usuario del dominio (fk_<dominio>, el del pool PHP). El usuario SFTP es un alias
# con el MISMO UID que fk_<dominio> (useradd -o, como las cuentas FTP de Froxlor): lo que sube por SFTP es
# del usuario del pool (PHP puede modificarlo) y el chroot impide salir de /var/www/vhosts/<dominio>.
fix_domain_chroot_perms() {
  local domain="$1"
  local sftp_user="${2:-}"
  local vroot="${VHOSTS_ROOT:-/var/www/vhosts}/$domain"
  [[ -d "$vroot" ]] || die 3 "Falta árbol de dominio: $vroot"
  if ! iso_is_isolated "$domain"; then
    bash "$FRESK_ROOT/scripts/domain-isolate.sh" "$domain" >/dev/null || die 6 "No se pudo aislar $domain (flesk domain isolate $domain)"
  fi
  iso_fix_perms "$domain"
  if [[ -n "$sftp_user" ]]; then
    gpasswd -a "$sftp_user" "$(iso_domain_user "$domain")" >/dev/null
  fi
}

require_root
ensure_installed
ensure_sftponly_group

if [[ $# -lt 2 ]]; then usage; die 2 "Faltan dominio y usuario"; fi

DOMAIN_RAW="$1"
USER_RAW="$2"
shift 2
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

DOMAIN="$(valid_domain "$DOMAIN_RAW")" || die 2 "Dominio inválido: $DOMAIN_RAW"
USERNAME="$(valid_sftp_username "$USER_RAW")" || die 2 "Usuario inválido o reservado: $USER_RAW"

VHOSTS_ROOT="${VHOSTS_ROOT:-/var/www/vhosts}"
DOMAIN_HOME="$VHOSTS_ROOT/$DOMAIN"
DOCROOT="$DOMAIN_HOME/httpdocs"
SYS_USER="$USERNAME"

# Prefijo si colisiona con cuenta de sistema ajena al panel
if id "$SYS_USER" >/dev/null 2>&1; then
  EXISTING_PANEL="$(mysql_q -e "SELECT id FROM sftp_users WHERE system_user='${SYS_USER}' LIMIT 1;" 2>/dev/null || true)"
  if [[ -z "$EXISTING_PANEL" ]]; then
    # Intentar prefijo sftp_
    CAND="sftp_${USERNAME}"
    CAND="${CAND:0:32}"
    if [[ ! "$CAND" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || sftp_reserved_user "$CAND"; then
      die 4 "Colisión con usuario de sistema '$USERNAME' y no se pudo derivar nombre seguro"
    fi
    if id "$CAND" >/dev/null 2>&1; then
      EXISTING_PANEL2="$(mysql_q -e "SELECT id FROM sftp_users WHERE system_user='${CAND}' LIMIT 1;" 2>/dev/null || true)"
      if [[ -z "$EXISTING_PANEL2" ]]; then
        die 4 "Colisión: '$USERNAME' y '$CAND' ya existen en el sistema"
      fi
    fi
    log "WARN" "Usuario $USERNAME existe en sistema; usando system_user=$CAND"
    SYS_USER="$CAND"
  fi
fi

lock "sftp:$USERNAME"
trap 'unlock' EXIT
rb_reset

DOMAIN_ID="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' AND status='active' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$DOMAIN_ID" ]]; then
  die 3 "Dominio no existe o no está active: $DOMAIN (flesk domain add $DOMAIN)"
fi

if [[ ! -d "$DOMAIN_HOME" || ! -d "$DOCROOT" ]]; then
  die 3 "Falta docroot de dominio: $DOCROOT"
fi

# Idempotencia: misma fila + usuario de sistema correcto
EXISTING="$(mysql_q -e "SELECT id, domain_id, system_user FROM sftp_users WHERE username='${USERNAME}' LIMIT 1;" 2>/dev/null || true)"
[[ -z "$EXISTING" ]] && mini_check sftp_users "usuario FTP/SFTP" "FTP/SFTP user"   # Flesk Mini
if [[ -n "$EXISTING" ]]; then
  EX_ID="$(printf '%s' "$EXISTING" | awk '{print $1}')"
  EX_DOM="$(printf '%s' "$EXISTING" | awk '{print $2}')"
  EX_SYS="$(printf '%s' "$EXISTING" | awk '{print $3}')"
  if [[ "$EX_DOM" == "$DOMAIN_ID" ]] && id "$EX_SYS" >/dev/null 2>&1; then
    # Asegurar perms / grupo
    usermod -g sftponly -d "$DOMAIN_HOME" -s /usr/sbin/nologin "$EX_SYS" 2>/dev/null || true
    fix_domain_chroot_perms "$DOMAIN" "$EX_SYS"
    log "INFO" "sftp.add $USERNAME@$DOMAIN idempotente (ya activo)"
    audit "cli" "sftp.add" "$USERNAME" "ok" "idempotent domain=$DOMAIN"
    echo "OK sftp_user=$USERNAME domain=$DOMAIN system_user=$EX_SYS (ya existía)"
    exit 0
  fi
  die 4 "Usuario SFTP $USERNAME ya vinculado a otro dominio o estado inconsistente (id=$EX_ID)"
fi

if [[ -z "$PLAIN_PASS" ]]; then
  PLAIN_PASS="$(gen_password)"
fi

# Dominio aislado (usuario fk_<dominio> + pool propio) antes de crear el alias SFTP
fix_domain_chroot_perms "$DOMAIN" ""
DOM_USER="$(iso_domain_user "$DOMAIN")"
DOM_UID="$(id -u "$DOM_USER")" || die 3 "El dominio no tiene usuario propio"
[[ "$DOM_UID" -ne 0 ]] || die 3 "UID 0 no permitido"

CREATED_USER=0
if ! id "$SYS_USER" >/dev/null 2>&1; then
  useradd -o -u "$DOM_UID" -g sftponly -G "$DOM_USER" -d "$DOMAIN_HOME" -s /usr/sbin/nologin -M "$SYS_USER"
  CREATED_USER=1
  rb_push "userdel -f $(printf '%q' "$SYS_USER") 2>/dev/null || true"
else
  # Usuario ya era nuestro (re-alta tras borrado parcial): reconfigurar
  usermod -g sftponly -d "$DOMAIN_HOME" -s /usr/sbin/nologin "$SYS_USER"
  usermod -U "$SYS_USER" 2>/dev/null || true
fi

if ! printf '%s:%s\n' "$SYS_USER" "$PLAIN_PASS" | chpasswd; then
  rb_run
  die 6 "No se pudo fijar contraseña; rollback ejecutado"
fi

fix_domain_chroot_perms "$DOMAIN" "$SYS_USER"

if ! mysql_q -e "INSERT INTO sftp_users (domain_id, username, system_user)
  VALUES (${DOMAIN_ID}, '${USERNAME}', '${SYS_USER}');"; then
  rb_run
  audit "cli" "sftp.add" "$USERNAME" "fail" "mysql insert"
  die 6 "Fallo al insertar sftp_users; rollback ejecutado"
fi
rb_push "mysql_q -e \"DELETE FROM sftp_users WHERE username='${USERNAME}' LIMIT 1;\""

rb_reset
log "INFO" "sftp.add $USERNAME ok domain=$DOMAIN system_user=$SYS_USER home=$DOMAIN_HOME created=$CREATED_USER"
audit "cli" "sftp.add" "$USERNAME" "ok" "domain=$DOMAIN system_user=$SYS_USER"
echo "OK sftp_user=$USERNAME domain=$DOMAIN system_user=$SYS_USER home=$DOMAIN_HOME"
echo "PASSWORD=${PLAIN_PASS}"
exit 0
