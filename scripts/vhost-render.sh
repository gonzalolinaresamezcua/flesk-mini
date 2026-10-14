#!/usr/bin/env bash
# Flesk — regenera el vhost nginx de un dominio desde la plantilla actual (HTTP o HTTPS según el vhost vigente)
#   flesk domain render <dominio>
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
require_root
[[ $# -ge 1 ]] || die 2 "Uso: flesk domain render <dominio>"
DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"
VF="$NGINX_ENABLED/$DOMAIN.conf"
[[ -f "$VF" ]] || die 3 "Sin vhost para $DOMAIN"
SOCK="$(grep -o 'unix:[^;]*' "$VF" | head -1 | sed 's/^unix://')"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/isolation.sh"
[[ -n "$SOCK" && "$SOCK" != "$PANEL_FPM_SOCK" ]] || SOCK="$(iso_sock "$DOMAIN")"
TMP="$(mktemp "$FRESK_RUN/vhost.XXXXXX")"
if grep -q 'listen 443' "$VF"; then
  CERT="$(awk '/ssl_certificate /{gsub(";","",$2); print $2; exit}' "$VF")"
  KEY="$(awk '/ssl_certificate_key /{gsub(";","",$2); print $2; exit}' "$VF")"
  render_template "$FRESK_ROOT/templates/nginx-vhost-ssl.conf" "$TMP" "DOMAIN=$DOMAIN" "PHP_FPM_SOCK=$SOCK" "SSL_CERT=$CERT" "SSL_KEY=$KEY"
else
  render_template "$FRESK_ROOT/templates/nginx-vhost.conf" "$TMP" "DOMAIN=$DOMAIN" "PHP_FPM_SOCK=$SOCK"
fi
# Document root alternativo (flesk git deploy en la raíz: raíz web del repositorio en apps/), validado dentro del dominio
DR_FILE="/etc/nginx/fresk-apps/$DOMAIN/docroot"
if [[ -f "$DR_FILE" ]]; then
  DR="$(head -1 "$DR_FILE")"
  if [[ "$DR" =~ ^/[A-Za-z0-9._/-]+$ && "$DR" == "${VHOSTS_ROOT:-/var/www/vhosts}/$DOMAIN/"* && "$DR" != *..* ]]; then
    sed -i "s#^\([[:space:]]*root \)/var/www/vhosts/$DOMAIN/httpdocs;#\1$DR;#" "$TMP"
  else
    log "WARN" "docroot alternativo ignorado para $DOMAIN (ruta no válida)"
  fi
fi
if cmp -s "$TMP" "$VF"; then rm -f "$TMP"; echo "OK vhost $DOMAIN (sin cambios)"; exit 0; fi
BAK="$FRESK_RUN/vhost.bak.$$"; cp -a "$VF" "$BAK"
atomic_install "$TMP" "$VF" 644 root:root
if nginx -t 2>/tmp/fresk-nginx-t.err; then
  reload_service nginx; rm -f "$BAK"
  SYS="${VHOSTS_ROOT:-/var/www/vhosts}/system/$DOMAIN/conf"; [[ -d "$SYS" ]] && cp -a "$VF" "$SYS/nginx.conf"
  audit "cli" "domain.render" "$DOMAIN" "ok" ""
  echo "OK vhost $DOMAIN regenerado"
else
  cat /tmp/fresk-nginx-t.err >&2 || true
  cp -a "$BAK" "$VF"; rm -f "$BAK"; nginx -t >/dev/null 2>&1 && reload_service nginx || true
  die 6 "nginx -t falló; vhost restaurado"
fi
