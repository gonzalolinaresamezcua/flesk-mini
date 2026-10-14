#!/usr/bin/env bash
# Flesk — ajusta dueño/permisos tras operaciones del gestor de archivos del panel.
# Uso: flesk files fixperms <dominio> <ruta-relativa-a-httpdocs>
# Solo dentro de /var/www/vhosts/<dominio>/httpdocs; nunca sigue symlinks; sin recursión.
# Dueño = dueño de httpdocs (usuario del dominio fk_<dominio>), grupo = grupo de httpdocs; ficheros u+rw,g+rw,o=r; dirs 2775
# (httpdocs es 2770: solo el sitio, nginx y el panel entran).
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed

[[ $# -eq 2 ]] || die 2 "Uso: flesk files fixperms <dominio> <ruta-relativa>"
DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido"
REL="$2"

# Validación de la ruta relativa
[[ -n "$REL" ]] || die 2 "Ruta vacía"
[[ ${#REL} -le 1024 ]] || die 2 "Ruta demasiado larga"
[[ "$REL" != /* ]] || die 2 "Ruta absoluta no permitida"
[[ "$REL" != *$'\n'* && "$REL" != *$'\r'* ]] || die 2 "Ruta inválida"
case "/$REL/" in
  */../*|*/./*) die 2 "Ruta con segmentos . o .. no permitida" ;;
esac

# El dominio debe existir en Flesk
ROW="$(mysql_q -e "SELECT id FROM domains WHERE name='${DOMAIN}' LIMIT 1;" 2>/dev/null || true)"
[[ -n "$ROW" ]] || die 3 "Dominio no registrado en Flesk"

VHOSTS_ROOT="${VHOSTS_ROOT:-/var/www/vhosts}"
WEB_USER="${WEB_USER:-www-data}"
DOCROOT="$VHOSTS_ROOT/$DOMAIN/httpdocs"
[[ -d "$DOCROOT" && ! -L "$DOCROOT" ]] || die 3 "Falta httpdocs"
DOCREAL="$(realpath -e -- "$DOCROOT")"

TARGET="$DOCROOT/$REL"
[[ -e "$TARGET" ]] || die 3 "No existe"
[[ ! -L "$TARGET" ]] || die 2 "Symlink: no se modifica"
REAL="$(realpath -e -- "$TARGET")"
case "$REAL" in
  "$DOCREAL"/*) ;;
  *) die 2 "Fuera de httpdocs" ;;
esac

OWNER="$(stat -c %U -- "$DOCREAL")"
GROUP="$(stat -c %G -- "$DOCREAL")"
if [[ -d "$REAL" ]]; then
  chown "${OWNER}:${GROUP}" -- "$REAL"
  chmod 2775 -- "$REAL"
elif [[ -f "$REAL" ]]; then
  chown "${OWNER}:${GROUP}" -- "$REAL"
  chmod u+rw,g+rw,o+r,o-wx -- "$REAL"
else
  die 2 "Tipo de fichero no soportado"
fi
echo "OK $DOMAIN $REL owner=$OWNER"
exit 0
