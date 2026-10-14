#!/usr/bin/env bash
# Flesk Mini — límites de la edición de prueba (se aplican en el motor, no solo en la interfaz).
# 1 dominio · 1 buzón de correo · 1 certificado SSL · 1 base de datos · 1 usuario SFTP/FTP.
# Para más: Flesk gratuito (3 dominios, licencia anual gratis con registro) o Flesk de pago (ilimitado + IA) en https://serverflesk.es
# shellcheck disable=SC2034
FLESK_EDITION="mini"
FLESK_MINI_MAX=1
FLESK_MINI_URL="https://serverflesk.es/descargar"

# mini_limit_reached <recurso legible ES> <recurso legible EN>
mini_limit_reached() {
  local es="$1" en="${2:-$1}"
  echo "FLESK_MINI_LIMIT: Flesk Mini permite solo 1 ${es}. ¿Necesitas más? Flesk gratuito (hasta 3 dominios, licencia anual gratis tras registrarte) o Flesk de pago (todo incluido, dominios ilimitados e IA operativa): ${FLESK_MINI_URL} | Flesk Mini allows only 1 ${en}. Need more? Free Flesk (up to 3 domains, free yearly licence after registering) or paid Flesk (everything included, unlimited domains, working AI): ${FLESK_MINI_URL}" >&2
  audit "cli" "mini.limit" "$en" "fail" "limit=${FLESK_MINI_MAX}" 2>/dev/null || true
  exit 7
}

# mini_check <tabla> <es> <en>: aborta si ya hay FLESK_MINI_MAX filas en la tabla
mini_check() {
  local table="$1" n
  case "$table" in domains|mailboxes|databases|sftp_users|ssl_certs) ;; *) die 2 "mini_check: tabla no permitida" ;; esac
  n="$(mysql_q -e "SELECT COUNT(*) FROM \`${table}\`;" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n >= FLESK_MINI_MAX )); then mini_limit_reached "$2" "$3"; fi
}
