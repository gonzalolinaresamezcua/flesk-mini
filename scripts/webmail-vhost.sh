#!/usr/bin/env bash
# Flesk — vhost nginx de Roundcube en webmail.<dominio>
#   flesk webmail vhost <dominio>      crea/actualiza (HTTPS si hay certificado que cubra webmail.<dominio>:
#                                      el del dominio o uno propio /etc/letsencrypt/live/webmail.<dominio>)
#   flesk webmail ssl <dominio>        emite (Let's Encrypt, webroot) el certificado propio de webmail.<dominio>
#                                      si su A/AAAA apunta a este servidor, y activa HTTPS; si no, aviso claro (rc=5)
#   flesk webmail remove <dominio>     lo elimina (y su certificado propio)
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ACTION="${1:-}"; shift || true
[[ $# -ge 1 ]] || die 2 "Uso: flesk webmail vhost|ssl|remove <dominio>"
DOMAIN="$(valid_domain "$1")" || die 2 "Dominio inválido: $1"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"
VF="$NGINX_ENABLED/${DOMAIN}.webmail.conf"
SNIP=/etc/nginx/snippets/flesk-roundcube.conf
HOST="webmail.$DOMAIN"
WEBROOT_ACME="${WEBROOT_ACME:-/var/www/letsencrypt}"

# Certificado que cubre webmail.<dominio>: el del dominio (SAN) o el propio webmail.<dominio>. Imprime "cert key".
pick_cert() {
  local base
  for base in "/etc/letsencrypt/live/$DOMAIN" "/etc/letsencrypt/live/$HOST"; do
    if [[ -f "$base/privkey.pem" ]] && cert_covers "$base/fullchain.pem" "$HOST"; then
      echo "$base/fullchain.pem $base/privkey.pem"; return 0
    fi
  done
  return 1
}

# IPs públicas de un nombre (A o AAAA) vía resolvedor público, con respaldo local
resolve_ips() {
  local t="$1" n="$2" out=""
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short "$t" "$n" @8.8.8.8 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true)"
    [[ -z "$out" ]] && out="$(dig +short "$t" "$n" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true)"
  elif command -v getent >/dev/null 2>&1; then
    if [[ "$t" == A ]]; then out="$(getent ahostsv4 "$n" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    else out="$(getent ahostsv6 "$n" 2>/dev/null | awk '{print $1}' | sort -u || true)"; fi
  fi
  printf '%s' "$out"
}

nginx_apply_or_restore() {
  local bak="$1"
  if nginx -t 2>/tmp/fresk-nginx-t.err; then reload_service nginx; return 0; fi
  cat /tmp/fresk-nginx-t.err >&2 || true
  if [[ -n "$bak" && -f "$bak" ]]; then cp -a "$bak" "$VF"; else rm -f "$VF"; fi
  nginx -t >/dev/null 2>&1 && reload_service nginx || true
  return 1
}

case "$ACTION" in
  vhost|add|update)
    if [[ ! -d /opt/roundcube/public_html || ! -f "$SNIP" ]]; then
      log "WARN" "webmail: Roundcube no instalado (flesk mail setup); se omite $DOMAIN"
      echo "SKIP webmail $DOMAIN (roundcube no instalado)"; exit 0
    fi
    lock "webmail:$DOMAIN"; trap 'unlock' EXIT
    TMP="$(mktemp "$FRESK_RUN/webmail.XXXXXX")"
    MODE=http
    if CK="$(pick_cert)"; then
      MODE=https; CERT="${CK% *}"; KEY="${CK#* }"
      render_template "$FRESK_ROOT/templates/nginx-webmail-ssl.conf" "$TMP" "DOMAIN=$DOMAIN" "SSL_CERT=$CERT" "SSL_KEY=$KEY"
    else
      render_template "$FRESK_ROOT/templates/nginx-webmail-http.conf" "$TMP" "DOMAIN=$DOMAIN"
    fi
    BAK=""
    if [[ -f "$VF" ]]; then BAK="$FRESK_RUN/webmail.bak.$$"; cp -a "$VF" "$BAK"; fi
    atomic_install "$TMP" "$VF" 644 root:root
    if ! nginx_apply_or_restore "$BAK"; then rm -f "$BAK"; die 6 "nginx -t falló; webmail de $DOMAIN restaurado"; fi
    rm -f "$BAK"
    audit "cli" "webmail.vhost" "$DOMAIN" "ok" "$MODE"
    echo "OK webmail domain=$DOMAIN mode=$MODE host=webmail.$DOMAIN"
    ;;
  ssl|issue|cert)
    if [[ ! -d /opt/roundcube/public_html || ! -f "$SNIP" ]]; then
      die 3 "Roundcube no instalado (flesk mail setup); no se emite certificado para $HOST"
    fi
    # Ya cubierto (cert del dominio o propio): solo asegurar vhost HTTPS
    if pick_cert >/dev/null; then
      bash "$0" vhost "$DOMAIN"
      echo "OK webmail-ssl domain=$DOMAIN host=$HOST cert=existente"
      exit 0
    fi
    # Flesk Mini: no se emite un segundo certificado. Incluye webmail.<dominio> en el certificado del dominio
    # (flesk ssl issue <dominio> lo añade si su DNS apunta aquí) y vuelve a ejecutar.
    echo "SKIP webmail-ssl domain=$DOMAIN: Flesk Mini usa 1 solo certificado SSL; webmail.$DOMAIN queda en HTTP hasta que el certificado del dominio lo cubra. Más en https://serverflesk.es"
    exit 0
    WANT4="${PUBLIC_IP:-}"; WANT6="$(fresk_ipv6)"
    [[ -n "$WANT4" ]] || die 3 "PUBLIC_IP vacío en config.conf; no se puede verificar DNS de $HOST"
    A="$(resolve_ips A "$HOST" | tr '\n' ' ' | sed 's/ *$//')"
    AAAA="$(resolve_ips AAAA "$HOST" | tr '\n' ' ' | sed 's/ *$//')"
    if ! grep -qxF "$WANT4" <<< "$(tr ' ' '\n' <<< "$A")"; then
      msg="Webmail SSL pendiente: $HOST no apunta a este servidor (A=${A:-ninguno}; esperado $WANT4). Crea en el DNS del dominio un registro A 'webmail' → $WANT4${WANT6:+ (y AAAA → $WANT6, o ninguno)}, espera la propagación y vuelve a pulsar «Webmail HTTPS» (flesk webmail ssl $DOMAIN)."
      log "WARN" "$msg"; audit "cli" "webmail.ssl" "$DOMAIN" "skip" "dns-mismatch A=${A:-none}"
      die 5 "$msg"
    fi
    # Let's Encrypt valida por IPv6 si existe AAAA: debe ser la de este servidor
    if [[ -n "$AAAA" ]] && { [[ -z "$WANT6" ]] || ! grep -qxiF "$WANT6" <<< "$(tr ' ' '\n' <<< "$AAAA")"; }; then
      msg="Webmail SSL pendiente: $HOST tiene AAAA=${AAAA} que no es la IPv6 de este servidor (${WANT6:-sin IPv6 configurada}). Corrige o borra ese registro AAAA (Let's Encrypt valida por IPv6) y reintenta: flesk webmail ssl $DOMAIN"
      log "WARN" "$msg"; audit "cli" "webmail.ssl" "$DOMAIN" "skip" "dns-mismatch AAAA"
      die 5 "$msg"
    fi
    lock "webmail-ssl:$DOMAIN"; trap 'unlock' EXIT
    # El vhost HTTP de webmail sirve /.well-known/acme-challenge desde $WEBROOT_ACME
    [[ -f "$VF" ]] || bash "$0" vhost "$DOMAIN" >/dev/null
    mkdir -p "$WEBROOT_ACME/.well-known/acme-challenge"
    EMAIL="${LE_EMAIL:-${ADMIN_EMAIL:-}}"
    ARGS=(certonly --cert-name "$HOST" --webroot -w "$WEBROOT_ACME" -d "$HOST"
          --agree-tos --non-interactive --keep-until-expiring --key-type ecdsa)
    if [[ -z "$EMAIL" || "$EMAIL" == *@localhost || "$EMAIL" == *@local ]]; then
      ARGS+=(--register-unsafely-without-email)
    else
      ARGS+=(-m "$EMAIL")
    fi
    log "INFO" "webmail.ssl $DOMAIN: certbot webroot para $HOST"
    set +e
    certbot "${ARGS[@]}" >"$FRESK_RUN/webmail-certbot.out" 2>"$FRESK_RUN/webmail-certbot.err"
    RC=$?
    set -e
    if [[ $RC -ne 0 ]]; then
      tail -n 20 "$FRESK_RUN/webmail-certbot.err" >&2 || true
      audit "cli" "webmail.ssl" "$DOMAIN" "fail" "certbot rc=$RC"
      die 5 "certbot falló para $HOST (rc=$RC). Revisa DNS/puerto 80. Detalle: $FRESK_RUN/webmail-certbot.err"
    fi
    unlock; trap - EXIT
    bash "$0" vhost "$DOMAIN"
    NA="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$HOST/cert.pem" 2>/dev/null | sed 's/notAfter=//' || true)"
    audit "cli" "webmail.ssl" "$DOMAIN" "ok" "cert=$HOST not_after=$NA"
    echo "OK webmail-ssl domain=$DOMAIN host=$HOST cert=/etc/letsencrypt/live/$HOST not_after=$NA"
    ;;
  remove|del|rm)
    if [[ -f "$VF" ]]; then
      backup_file "$VF"; rm -f "$VF"
      nginx -t >/dev/null 2>&1 && reload_service nginx || true
      audit "cli" "webmail.remove" "$DOMAIN" "ok" ""
    fi
    # Certificado propio de webmail.<dominio> (si existe): ya no hay vhost que lo use
    if [[ -d "/etc/letsencrypt/live/$HOST" ]] && command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$HOST" --non-interactive >"$FRESK_RUN/webmail-certbot.out" 2>&1 || log "WARN" "no se pudo borrar el certificado $HOST"
    fi
    echo "OK webmail removed $DOMAIN"
    ;;
  *) die 2 "Acción inválida: $ACTION" ;;
esac
