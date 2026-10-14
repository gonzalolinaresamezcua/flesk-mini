#!/usr/bin/env bash
# Flesk — emisión Let's Encrypt (fase 3): certbot --webroot + vhost HTTPS
# Alias CLI: flesk ssl obtain|issue <dominio> [--staging] [--force]
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/limits.sh"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/rollback.sh"

usage() {
  echo "Uso: flesk ssl obtain|issue <dominio> [--staging] [--force] [--dry-run]" >&2
  echo "  Emite certificado Let's Encrypt por webroot y activa HTTPS." >&2
  echo "  Requiere que el dominio resuelva a PUBLIC_IP (${PUBLIC_IP:-?})." >&2
  echo "  Dominios .local / sin DNS público: se omiten con error claro (sin crash)." >&2
}

require_root
ensure_installed

if [[ $# -lt 1 ]]; then usage; die 2 "Falta dominio"; fi

DOMAIN_RAW="$1"
shift
STAGING=0
FORCE=0
DRYRUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging) STAGING=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "Argumento desconocido: $1" ;;
  esac
done

DOMAIN="$(valid_domain "$DOMAIN_RAW")" || die 2 "Dominio inválido: $DOMAIN_RAW"

PUBLIC_IP="${PUBLIC_IP:-}"
VHOSTS_ROOT="${VHOSTS_ROOT:-/var/www/vhosts}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/fresk-enabled}"
WEBROOT_ACME="${WEBROOT_ACME:-/var/www/letsencrypt}"
DOCROOT="$VHOSTS_ROOT/$DOMAIN/httpdocs"
VHOST_FILE="$NGINX_ENABLED/${DOMAIN}.conf"
SYS_CONF="$VHOSTS_ROOT/system/$DOMAIN/conf"
REF_VHOST="$SYS_CONF/nginx.conf"
LE_LIVE="/etc/letsencrypt/live/${DOMAIN}"
SSL_CERT="${LE_LIVE}/fullchain.pem"
SSL_KEY="${LE_LIVE}/privkey.pem"

# --- Email LE ---
resolve_le_email() {
  local email="${LE_EMAIL:-}"
  if [[ -z "$email" ]]; then
    email="${ADMIN_EMAIL:-}"
  fi
  # Placeholder / localhost → sin email (registro inseguro solo si hace falta)
  if [[ -z "$email" || "$email" == "admin@localhost" || "$email" =~ @localhost$ || "$email" =~ @local$ ]]; then
    printf ''
    return 0
  fi
  printf '%s' "$email"
}

# --- DNS: debe apuntar a PUBLIC_IP ---
domain_resolves_to_public() {
  local d="$1"
  local want="$2"
  [[ -n "$want" ]] || return 1
  local ips=""
  if command -v dig >/dev/null 2>&1; then
    ips="$(dig +short A "$d" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  fi
  if [[ -z "$ips" ]] && command -v getent >/dev/null 2>&1; then
    ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  fi
  if [[ -z "$ips" ]]; then
    return 1
  fi
  local ip
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    if [[ "$ip" == "$want" ]]; then
      return 0
    fi
  done <<< "$ips"
  return 1
}

is_lab_or_private_tld() {
  local d="$1"
  case "$d" in
    *.local|*.localhost|*.test|*.invalid|*.example|localhost) return 0 ;;
  esac
  return 1
}

lock "ssl:$DOMAIN"
trap 'unlock' EXIT
rb_reset

# Dominio debe existir en panel
DOMAIN_ROW="$(mysql_q -e "SELECT id, php_version, status FROM domains WHERE name='${DOMAIN}' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$DOMAIN_ROW" ]]; then
  die 3 "El dominio $DOMAIN no está en Flesk. Primero: flesk domain add $DOMAIN"
fi
DOMAIN_ID="$(printf '%s' "$DOMAIN_ROW" | awk '{print $1}')"
PHP_VER="$(printf '%s' "$DOMAIN_ROW" | awk '{print $2}')"
DOM_STATUS="$(printf '%s' "$DOMAIN_ROW" | awk '{print $3}')"
# Flesk Mini: un único certificado (el del dominio del panel); renovar el mismo sí se permite
OTHER_CERT="$(mysql_q -e "SELECT id FROM ssl_certs WHERE domain_id<>${DOMAIN_ID} LIMIT 1;" 2>/dev/null || true)"
[[ -n "$OTHER_CERT" ]] && mini_limit_reached "certificado SSL" "SSL certificate"
if [[ "$DOM_STATUS" != "active" ]]; then
  die 3 "Dominio $DOMAIN no está active (status=$DOM_STATUS)"
fi

if [[ ! -d "$DOCROOT" || ! -f "$VHOST_FILE" ]]; then
  die 3 "Falta docroot o vhost HTTP para $DOMAIN. Revisa: flesk domain add $DOMAIN"
fi

# Dominios de laboratorio / TLD privadas: error claro, sin crash ni certbot
if is_lab_or_private_tld "$DOMAIN"; then
  msg="SSL omitido: '$DOMAIN' es un dominio de laboratorio (.local/.test/…). Let's Encrypt no emite para TLDs privadas. Apunta un dominio real (A → ${PUBLIC_IP:-IP_PUBLICA}) y vuelve a ejecutar: flesk ssl issue $DOMAIN. Autofirmado de lab no está en el MVP (ver instrucciones.md)."
  log "WARN" "$msg"
  mysql_q -e "INSERT INTO ssl_certs (domain_id, issuer, not_after, path_fullchain, path_key, status)
    VALUES (${DOMAIN_ID}, 'none', NULL, '/dev/null', '/dev/null', 'error')
    ON DUPLICATE KEY UPDATE issuer='none', status='error', path_fullchain='/dev/null', path_key='/dev/null';" 2>/dev/null || true
  audit "cli" "ssl.obtain" "$DOMAIN" "skip" "lab-tld"
  die 5 "$msg"
fi

if [[ -z "$PUBLIC_IP" ]]; then
  die 3 "PUBLIC_IP vacío en config.conf; no se puede verificar DNS"
fi

# --- Método y nombres ---
# DNS-01 (comodín *.dominio) solo si la delegación NS apunta a este servidor y BIND es público;
# si no, HTTP-01 con SAN: el dominio + www/webmail/mail que ya resuelvan a esta IP.
ns_points_here() {
  local mode="${DNS_PUBLIC:-no}"; mode="${mode,,}"
  [[ "$mode" == "yes" || "$mode" == "true" || "$mode" == "1" ]] || return 1
  command -v dig >/dev/null 2>&1 || return 1
  local ns ip
  for ns in $(dig +short NS "$DOMAIN" @1.1.1.1 2>/dev/null); do
    for ip in $(dig +short A "$ns" @1.1.1.1 2>/dev/null); do
      [[ "$ip" == "$PUBLIC_IP" ]] && return 0
    done
  done
  return 1
}
METHOD="http-01"; NAMES=(); MISSING=()
if ns_points_here; then
  METHOD="dns-01"; NAMES=("$DOMAIN" "*.$DOMAIN")
else
  if ! domain_resolves_to_public "$DOMAIN" "$PUBLIC_IP"; then
    resolved="$(dig +short A "$DOMAIN" 2>/dev/null | tr '\n' ' ' || true)"
    msg="SSL omitido: '$DOMAIN' no resuelve a PUBLIC_IP=${PUBLIC_IP} (resuelve a: ${resolved:-ninguna}). Crea un registro A → ${PUBLIC_IP} y espera propagación DNS. Sin DNS público Let's Encrypt falla el challenge HTTP-01."
    log "WARN" "$msg"
    mysql_q -e "INSERT INTO ssl_certs (domain_id, issuer, not_after, path_fullchain, path_key, status, method, names, note)
      VALUES (${DOMAIN_ID}, 'none', NULL, '/dev/null', '/dev/null', 'error', 'http-01', '', 'dns-mismatch')
      ON DUPLICATE KEY UPDATE issuer='none', status='error', path_fullchain='/dev/null', path_key='/dev/null', note='dns-mismatch';" 2>/dev/null || true
    audit "cli" "ssl.obtain" "$DOMAIN" "skip" "dns-mismatch"
    die 5 "$msg"
  fi
  NAMES=("$DOMAIN")
  for h in www webmail mail; do
    if domain_resolves_to_public "$h.$DOMAIN" "$PUBLIC_IP"; then NAMES+=("$h.$DOMAIN"); else MISSING+=("$h.$DOMAIN"); fi
  done
fi
NOTE=""
if [[ ${#MISSING[@]} -gt 0 ]]; then
  NOTE="Sin DNS hacia ${PUBLIC_IP}: ${MISSING[*]} (no incluidos en el certificado; añade registros A/AAAA en el DNS del dominio y vuelve a emitir)"
  log "WARN" "ssl.obtain $DOMAIN: $NOTE"
fi
NAMES_CSV="$(IFS=,; echo "${NAMES[*]}")"
log "INFO" "ssl.obtain $DOMAIN: método=$METHOD nombres=$NAMES_CSV"

# Idempotencia: el certificado ya cubre todos los nombres y el vhost ya es HTTPS
if [[ "$FORCE" -eq 0 && "$DRYRUN" -eq 0 && -f "$SSL_CERT" && -f "$SSL_KEY" ]] && grep -q 'listen 443' "$VHOST_FILE" 2>/dev/null; then
  ALL=1
  for n in "${NAMES[@]}"; do cert_covers "$SSL_CERT" "$n" || { [[ "$n" == \** ]] && cert_names "$SSL_CERT" | grep -qxF "$n"; } || ALL=0; done
  if [[ "$ALL" -eq 1 ]]; then
    NA_SQL="NULL"
    NOT_AFTER="$(openssl x509 -enddate -noout -in "$SSL_CERT" 2>/dev/null | sed 's/notAfter=//' || true)"
    [[ -n "$NOT_AFTER" ]] && NA_SQL="'$(date -u -d "$NOT_AFTER" '+%Y-%m-%d %H:%M:%S')'"
    mysql_q -e "INSERT INTO ssl_certs (domain_id, issuer, not_after, path_fullchain, path_key, status, method, names, note)
      VALUES (${DOMAIN_ID}, 'letsencrypt', ${NA_SQL}, '${SSL_CERT}', '${SSL_KEY}', 'active', '${METHOD}', '$(cert_names "$SSL_CERT" | paste -sd, -)', '$(printf '%s' "$NOTE" | sed "s/'/''/g")')
      ON DUPLICATE KEY UPDATE issuer='letsencrypt', not_after=${NA_SQL}, path_fullchain='${SSL_CERT}', path_key='${SSL_KEY}',
        status='active', method=VALUES(method), names=VALUES(names), note=VALUES(note);" 2>/dev/null || true
    log "INFO" "ssl.obtain $DOMAIN idempotente (cert cubre $NAMES_CSV)"
    audit "cli" "ssl.obtain" "$DOMAIN" "ok" "idempotent"
    echo "OK domain=$DOMAIN ssl=active method=$METHOD names=$NAMES_CSV (ya existía)"
    [[ -n "$NOTE" ]] && echo "WARN $NOTE"
    exit 0
  fi
fi

# Socket PHP: el del vhost vigente (pool aislado del dominio) o, si no hay, el del pool flesk-<dominio>
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/isolation.sh"
PHP_FPM_SOCK="$(grep -o 'fastcgi_pass unix:[^;]*' "$VHOST_FILE" 2>/dev/null | head -1 | sed 's/^fastcgi_pass unix://' || true)"
[[ -n "$PHP_FPM_SOCK" && "$PHP_FPM_SOCK" != "$PANEL_FPM_SOCK" ]] || PHP_FPM_SOCK="$(iso_sock "$DOMAIN")"

mkdir -p "$WEBROOT_ACME/.well-known/acme-challenge"
chmod 755 /var/www/letsencrypt /var/www/letsencrypt/.well-known /var/www/letsencrypt/.well-known/acme-challenge 2>/dev/null || true

LE_EMAIL_RESOLVED="$(resolve_le_email)"
CERTBOT_ARGS=(certonly --cert-name "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring --expand)
if [[ "$METHOD" == "dns-01" ]]; then
  CERTBOT_ARGS+=(--manual --preferred-challenges dns
    --manual-auth-hook "$FRESK_ROOT/scripts/acme-dns-hook.sh auth"
    --manual-cleanup-hook "$FRESK_ROOT/scripts/acme-dns-hook.sh cleanup")
else
  CERTBOT_ARGS+=(--webroot -w "$WEBROOT_ACME")
fi
for n in "${NAMES[@]}"; do CERTBOT_ARGS+=(-d "$n"); done
if [[ "$DRYRUN" -eq 1 ]]; then CERTBOT_ARGS+=(--dry-run); fi
if [[ "$FORCE" -eq 1 ]]; then
  CERTBOT_ARGS+=(--force-renewal)
fi
if [[ "$STAGING" -eq 1 ]]; then
  CERTBOT_ARGS+=(--staging)
  log "INFO" "Usando Let's Encrypt staging"
fi
if [[ -n "$LE_EMAIL_RESOLVED" ]]; then
  CERTBOT_ARGS+=(-m "$LE_EMAIL_RESOLVED")
  log "INFO" "LE email desde config (LE_EMAIL/ADMIN_EMAIL)"
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
  log "WARN" "ADMIN_EMAIL/LE_EMAIL es placeholder (admin@localhost). Usando --register-unsafely-without-email. Configura LE_EMAIL real en config.conf."
fi

log "INFO" "ssl.obtain $DOMAIN: lanzando certbot webroot=$WEBROOT_ACME"
set +e
certbot "${CERTBOT_ARGS[@]}" >/tmp/fresk-certbot.out 2>/tmp/fresk-certbot.err
CB_RC=$?
set -e
if [[ $CB_RC -ne 0 ]]; then
  log "ERROR" "certbot falló (rc=$CB_RC) para $DOMAIN"
  tail -n 40 /tmp/fresk-certbot.err >&2 || true
  mysql_q -e "INSERT INTO ssl_certs (domain_id, issuer, not_after, path_fullchain, path_key, status)
    VALUES (${DOMAIN_ID}, 'letsencrypt', NULL, '/dev/null', '/dev/null', 'error')
    ON DUPLICATE KEY UPDATE status='error';" 2>/dev/null || true
  audit "cli" "ssl.obtain" "$DOMAIN" "fail" "certbot rc=$CB_RC"
  die 5 "certbot falló para $DOMAIN (¿DNS/firewall 80?). Ver /tmp/fresk-certbot.err"
fi

if [[ "$DRYRUN" -eq 1 ]]; then
  audit "cli" "ssl.obtain" "$DOMAIN" "ok" "dry-run method=$METHOD names=$NAMES_CSV"
  echo "OK dry-run domain=$DOMAIN method=$METHOD names=$NAMES_CSV"
  [[ -n "$NOTE" ]] && echo "WARN $NOTE"
  exit 0
fi

if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
  die 5 "certbot OK pero faltan $SSL_CERT o $SSL_KEY"
fi

NOT_AFTER_SQL=""
if command -v openssl >/dev/null 2>&1; then
  NOT_AFTER_RAW="$(openssl x509 -enddate -noout -in "$SSL_CERT" 2>/dev/null | sed 's/notAfter=//' || true)"
  if [[ -n "$NOT_AFTER_RAW" ]]; then
    NOT_AFTER_SQL="$(date -u -d "$NOT_AFTER_RAW" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  fi
fi

# Backup vhost actual y render SSL
backup_file "$VHOST_FILE"
# backup_file: / → _; tomar el más reciente de este vhost
PREV_BACKUP="$(ls -1t "$FRESK_BACKUPS"/*"${DOMAIN}.conf".* 2>/dev/null | head -1 || true)"

TMP_VHOST="$(mktemp "$FRESK_RUN/vhost-ssl.XXXXXX")"
rb_push "rm -f $(printf '%q' "$TMP_VHOST")"
render_template \
  "$FRESK_ROOT/templates/nginx-vhost-ssl.conf" \
  "$TMP_VHOST" \
  "DOMAIN=$DOMAIN" \
  "PHP_FPM_SOCK=$PHP_FPM_SOCK" \
  "SSL_CERT=$SSL_CERT" \
  "SSL_KEY=$SSL_KEY"
# Document root alternativo (flesk git deploy en la raíz del dominio)
if [[ -f "/etc/nginx/fresk-apps/$DOMAIN/docroot" ]]; then
  DR="$(head -1 "/etc/nginx/fresk-apps/$DOMAIN/docroot")"
  if [[ "$DR" =~ ^/[A-Za-z0-9._/-]+$ && "$DR" == "${VHOSTS_ROOT:-/var/www/vhosts}/$DOMAIN/"* && "$DR" != *..* ]]; then
    sed -i "s#^\([[:space:]]*root \)/var/www/vhosts/$DOMAIN/httpdocs;#\1$DR;#" "$TMP_VHOST"
  fi
fi

atomic_install "$TMP_VHOST" "$VHOST_FILE" 644 root:root
mkdir -p "$SYS_CONF"
cp -a "$VHOST_FILE" "$REF_VHOST"
chown root:root "$REF_VHOST"
chmod 644 "$REF_VHOST"

if ! nginx -t 2>/tmp/fresk-nginx-t.err; then
  log "ERROR" "nginx -t falló tras escribir vhost SSL; restaurando"
  cat /tmp/fresk-nginx-t.err >&2 || true
  if [[ -n "$PREV_BACKUP" && -f "$PREV_BACKUP" ]]; then
    cp -a "$PREV_BACKUP" "$VHOST_FILE"
    log "WARN" "Restaurado vhost desde $PREV_BACKUP"
  fi
  if nginx -t >/dev/null 2>&1; then
    reload_service nginx || true
  fi
  audit "cli" "ssl.obtain" "$DOMAIN" "fail" "nginx -t"
  die 6 "nginx -t falló; vhost anterior restaurado"
fi

reload_service nginx

ISSUER="letsencrypt"
if [[ "$STAGING" -eq 1 ]]; then
  ISSUER="letsencrypt-staging"
fi
NA_SQL="NULL"
if [[ -n "$NOT_AFTER_SQL" ]]; then
  NA_SQL="'${NOT_AFTER_SQL}'"
fi
mysql_q -e "INSERT INTO ssl_certs (domain_id, issuer, not_after, path_fullchain, path_key, status, method, names, note)
  VALUES (${DOMAIN_ID}, '${ISSUER}', ${NA_SQL}, '${SSL_CERT}', '${SSL_KEY}', 'active', '${METHOD}', '$(cert_names "$SSL_CERT" | paste -sd, -)', '$(printf '%s' "$NOTE" | sed "s/'/''/g")')
  ON DUPLICATE KEY UPDATE issuer='${ISSUER}', not_after=${NA_SQL}, path_fullchain='${SSL_CERT}',
    path_key='${SSL_KEY}', status='active', method=VALUES(method), names=VALUES(names), note=VALUES(note);"

# Webmail HTTPS (si el certificado cubre webmail.<dominio>) y certificados de Postfix/Dovecot
bash "$FRESK_ROOT/scripts/webmail-vhost.sh" vhost "$DOMAIN" >/dev/null 2>&1 || log "WARN" "webmail vhost falló para $DOMAIN"
bash "$FRESK_ROOT/scripts/mail-certs.sh" >/dev/null 2>&1 || log "WARN" "mail certs falló tras emitir $DOMAIN"

rb_reset
log "INFO" "ssl.obtain $DOMAIN ok cert=$SSL_CERT not_after=${NOT_AFTER_SQL:-?}"
audit "cli" "ssl.obtain" "$DOMAIN" "ok" "issuer=$ISSUER"
echo "OK domain=$DOMAIN ssl=active method=$METHOD names=$NAMES_CSV cert=$SSL_CERT"
[[ -n "$NOTE" ]] && echo "WARN $NOTE"
exit 0
