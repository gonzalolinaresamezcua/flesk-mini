#!/usr/bin/env bash
# Flesk — HTTPS del panel.
#   flesk panel ssl <dominio>       Let's Encrypt (webroot) para el dominio del panel; fija PANEL_DOMAIN;
#                                   http://IP/flesk y https://IP/flesk redirigen 301 a https://<dominio>/flesk/
#   flesk panel ssl --self-signed   Sin dominio: certificado autofirmado (SAN=IP) y panel en https://IP/flesk/
# Siempre: nginx -t antes de recargar; si falla, restaura la configuración anterior.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

usage() {
  echo "Uso: flesk panel ssl <dominio> [--staging] | flesk panel ssl --self-signed" >&2
}

require_root
ensure_installed

[[ $# -ge 1 ]] || { usage; die 2 "Falta dominio o --self-signed"; }

MODE="domain"
DOMAIN=""
STAGING=0
case "$1" in
  --self-signed) MODE="self" ;;
  -h|--help) usage; exit 0 ;;
  *) DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1" ;;
esac
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging) STAGING=1 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
  shift
done

PUBLIC_IP="${PUBLIC_IP:-$(detect_public_ip 2>/dev/null || true)}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"
# Pool propio del panel (usuario flesk); nunca el de un dominio
PHP_FPM_SOCK="${PANEL_FPM_SOCK:-/run/php/flesk-panel.sock}"
WEBROOT_ACME="${WEBROOT_ACME:-/var/www/letsencrypt}"
SNIP_ROOT="/etc/nginx/fresk-panel"
SSL_DIR="/etc/ssl/flesk"
TPL="$FRESK_ROOT/templates"

lock "panel-ssl"
trap 'unlock' EXIT

# --- Copia de seguridad de todo lo que se toca (restauración si nginx -t falla) ---
STAGE="$(mktemp -d "$FRESK_RUN/panel-ssl.XXXXXX")"
TOUCHED=()
save_state() {
  local f="$1"
  TOUCHED+=("$f")
  if [[ -e "$f" ]]; then
    mkdir -p "$STAGE$(dirname "$f")"
    cp -a "$f" "$STAGE$f"
    backup_file "$f"
  fi
}
restore_state() {
  local f
  for f in "${TOUCHED[@]}"; do
    if [[ -e "$STAGE$f" ]]; then cp -a "$STAGE$f" "$f"; else rm -f "$f"; fi
  done
}
nginx_apply() {
  if ! nginx -t 2>/tmp/fresk-nginx-t.err; then
    log "ERROR" "panel.ssl: nginx -t falló; restaurando"
    cat /tmp/fresk-nginx-t.err >&2 || true
    restore_state
    nginx -t >/dev/null 2>&1 && reload_service nginx || true
    audit "cli" "panel.ssl" "${DOMAIN:-self-signed}" "fail" "nginx -t"
    die 6 "nginx -t falló; configuración anterior restaurada"
  fi
  reload_service nginx
}

domain_resolves_to_public() {
  local d="$1" want="$2" ips=""
  [[ -n "$want" ]] || return 1
  if command -v dig >/dev/null 2>&1; then
    ips="$(dig +short A "$d" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  fi
  if [[ -z "$ips" ]]; then
    ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  fi
  grep -qxF "$want" <<< "$ips"
}

set_config() {
  local key="$1" val="$2"
  save_state "$FRESK_CONFIG"
  if grep -qE "^${key}=" "$FRESK_CONFIG"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$FRESK_CONFIG"
  else
    printf '%s=%s\n' "$key" "$val" >> "$FRESK_CONFIG"
  fi
}

# --- Certificado autofirmado (siempre: lo usa el server 443 por defecto) ---
ensure_selfsigned() {
  mkdir -p "$SSL_DIR"
  chmod 750 "$SSL_DIR"
  local crt="$SSL_DIR/panel-selfsigned.crt" key="$SSL_DIR/panel-selfsigned.key"
  local san="DNS:localhost"
  [[ -n "$PUBLIC_IP" ]] && san="IP:${PUBLIC_IP},${san}"
  if [[ -f "$crt" && -f "$key" ]] && openssl x509 -checkend 2592000 -noout -in "$crt" >/dev/null 2>&1 \
     && { [[ -z "$PUBLIC_IP" ]] || openssl x509 -noout -text -in "$crt" 2>/dev/null | grep -q "IP Address:${PUBLIC_IP}"; }; then
    return 0
  fi
  log "INFO" "panel.ssl: generando certificado autofirmado (SAN=${san})"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$key.tmp" -out "$crt.tmp" \
    -subj "/CN=${PUBLIC_IP:-flesk-panel}/O=Flesk" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1 || die 5 "openssl no pudo generar el certificado autofirmado"
  chmod 600 "$key.tmp"; chmod 644 "$crt.tmp"
  mv -f "$key.tmp" "$key"; mv -f "$crt.tmp" "$crt"
}

# --- Hook de renovación LE: recarga nginx tras renovar ---
ensure_renew_hook() {
  local hook="/etc/letsencrypt/renewal-hooks/deploy/flesk-reload-nginx.sh"
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" << 'HOOK'
#!/bin/sh
# Flesk: recarga nginx tras renovar cualquier certificado (panel y sitios)
nginx -t >/dev/null 2>&1 && systemctl reload nginx
HOOK
  chmod 755 "$hook"
}

resolve_le_email() {
  local email="${LE_EMAIL:-${ADMIN_EMAIL:-}}"
  if [[ -z "$email" || "$email" =~ @localhost$ || "$email" =~ @local$ ]]; then printf ''; else printf '%s' "$email"; fi
}

mkdir -p "$SNIP_ROOT/_default"
ensure_selfsigned

if [[ "$MODE" == "self" ]]; then
  # Panel en https://IP/flesk/ (autofirmado)
  save_state "$SNIP_ROOT/_default/panel.conf"
  save_state "$SNIP_ROOT/_default/redirect.conf"
  render_template "$TPL/nginx-panel-location.conf" "$SNIP_ROOT/_default/panel.conf" "PHP_FPM_SOCK=$PHP_FPM_SOCK"
  rm -f "$SNIP_ROOT/_default/redirect.conf"
  save_state "$NGINX_ENABLED/01-panel-ssl.conf"
  cp "$TPL/nginx-panel-ssl-default.conf" "$NGINX_ENABLED/01-panel-ssl.conf"
  save_state "$NGINX_ENABLED/00-panel.conf"
  render_template "$TPL/nginx-panel-server.conf" "$NGINX_ENABLED/00-panel.conf" \
    "PUBLIC_IP=${PUBLIC_IP:-0.0.0.0}" 'PANEL_HTTPS_ORIGIN=https://$host'
  # PANEL_DOMAIN no se toca (install.sh reintenta LE en la siguiente pasada si está definido)
  nginx_apply
  audit "cli" "panel.ssl" "self-signed" "ok" "ip=${PUBLIC_IP:-?}"
  echo "OK panel=https://${PUBLIC_IP:-IP}/flesk/ (certificado autofirmado: el navegador mostrará un aviso)"
  rm -rf "$STAGE"
  exit 0
fi

# --- Modo dominio ---
case "$DOMAIN" in
  *.local|*.localhost|*.test|*.invalid|*.example|localhost) die 2 "Dominio de laboratorio: usa --self-signed" ;;
esac
domain_resolves_to_public "$DOMAIN" "$PUBLIC_IP" || die 3 "$DOMAIN no resuelve a la IP del servidor (${PUBLIC_IP:-?}). Crea el registro A y reintenta."

LE_LIVE="/etc/letsencrypt/live/$DOMAIN"
IN_FLESK="$(mysql_q -e "SELECT COUNT(*) FROM domains WHERE name='${DOMAIN}' AND status='active';" 2>/dev/null || echo 0)"
IN_FLESK="${IN_FLESK//[^0-9]/}"

# Snippet del panel para el server 443 del dominio
save_state "$SNIP_ROOT/$DOMAIN/panel.conf"
mkdir -p "$SNIP_ROOT/$DOMAIN"
render_template "$TPL/nginx-panel-location.conf" "$SNIP_ROOT/$DOMAIN/panel.conf" "PHP_FPM_SOCK=$PHP_FPM_SOCK"

if [[ "${IN_FLESK:-0}" -gt 0 ]]; then
  # Dominio alojado en Flesk: cert + vhost SSL vía flesk ssl obtain (idempotente)
  VHOST="$NGINX_ENABLED/${DOMAIN}.conf"
  if ! { [[ -f "$LE_LIVE/fullchain.pem" ]] && grep -q 'listen 443' "$VHOST" 2>/dev/null; }; then
    bash "$FRESK_ROOT/scripts/ssl-obtain.sh" "$DOMAIN" $([[ $STAGING -eq 1 ]] && echo --staging) || die 5 "No se pudo emitir SSL para $DOMAIN"
  fi
  # vhost anterior a la plantilla con include: añadirlo tras server_name del bloque 443
  if ! grep -q "fresk-panel/${DOMAIN}/" "$VHOST"; then
    save_state "$VHOST"
    REF="${VHOSTS_ROOT:-/var/www/vhosts}/system/$DOMAIN/conf/nginx.conf"
    for f in "$VHOST" "$REF"; do
      [[ -f "$f" ]] || continue
      [[ "$f" == "$REF" ]] && save_state "$REF"
      awk -v inc="  include /etc/nginx/fresk-panel/${DOMAIN}/*.conf;" '
        /listen 443/ { in443=1 }
        { print }
        in443 && /server_name/ && !done { print "  # Panel Flesk (flesk panel ssl)"; print inc; done=1 }
      ' "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
    done
  fi
  rm -f "$NGINX_ENABLED/02-panel-domain.conf"
else
  # Dominio solo para el panel: certbot webroot (nunca --nginx) + server dedicado
  if [[ ! -f "$LE_LIVE/fullchain.pem" ]]; then
    # server 80 temporal para el reto ACME (el default ya sirve /.well-known)
    mkdir -p "$WEBROOT_ACME/.well-known/acme-challenge"
    ARGS=(certonly --webroot -w "$WEBROOT_ACME" -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
    [[ $STAGING -eq 1 ]] && ARGS+=(--staging)
    EM="$(resolve_le_email)"
    if [[ -n "$EM" ]]; then ARGS+=(-m "$EM"); else ARGS+=(--register-unsafely-without-email); fi
    certbot "${ARGS[@]}" >/tmp/fresk-certbot.out 2>/tmp/fresk-certbot.err || {
      tail -n 20 /tmp/fresk-certbot.err >&2 || true
      audit "cli" "panel.ssl" "$DOMAIN" "fail" "certbot"
      die 5 "certbot falló para $DOMAIN (¿DNS/puerto 80?)"
    }
  fi
  save_state "$NGINX_ENABLED/02-panel-domain.conf"
  render_template "$TPL/nginx-panel-domain.conf" "$NGINX_ENABLED/02-panel-domain.conf" "PANEL_DOMAIN=$DOMAIN"
fi

# IP (80 y 443 por defecto) → https://DOMINIO/flesk/
save_state "$SNIP_ROOT/_default/panel.conf"
save_state "$SNIP_ROOT/_default/redirect.conf"
rm -f "$SNIP_ROOT/_default/panel.conf"
render_template "$TPL/nginx-panel-redirect-location.conf" "$SNIP_ROOT/_default/redirect.conf" "PANEL_DOMAIN=$DOMAIN"
save_state "$NGINX_ENABLED/01-panel-ssl.conf"
cp "$TPL/nginx-panel-ssl-default.conf" "$NGINX_ENABLED/01-panel-ssl.conf"
save_state "$NGINX_ENABLED/00-panel.conf"
render_template "$TPL/nginx-panel-server.conf" "$NGINX_ENABLED/00-panel.conf" \
  "PUBLIC_IP=${PUBLIC_IP:-0.0.0.0}" "PANEL_HTTPS_ORIGIN=https://${DOMAIN}"

ensure_renew_hook
set_config PANEL_DOMAIN "$DOMAIN"
nginx_apply
audit "cli" "panel.ssl" "$DOMAIN" "ok" "letsencrypt"
echo "OK panel=https://${DOMAIN}/flesk/"
rm -rf "$STAGE"
exit 0
