#!/usr/bin/env bash
# Flesk — certificados de Postfix y Dovecot
#   flesk mail certs
# Certificado por defecto: el de PANEL_DOMAIN (Let's Encrypt) si existe; si no, el autofirmado del sistema.
# Además, por SNI, cada dominio cuyo certificado cubra mail./smtp./imap./pop.<dominio> usa el suyo.
# Comprueba la configuración antes de recargar y restaura la anterior si falla.
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed
lock "mail-certs"; trap 'unlock' EXIT

LE=/etc/letsencrypt/live
DEF_CERT=/etc/ssl/certs/ssl-cert-snakeoil.pem
DEF_KEY=/etc/ssl/private/ssl-cert-snakeoil.key
if [[ -n "${PANEL_DOMAIN:-}" && -f "$LE/$PANEL_DOMAIN/fullchain.pem" && -f "$LE/$PANEL_DOMAIN/privkey.pem" ]]; then
  DEF_CERT="$LE/$PANEL_DOMAIN/fullchain.pem"; DEF_KEY="$LE/$PANEL_DOMAIN/privkey.pem"
fi

PF_DIR=/etc/postfix/fresk
SNI="$PF_DIR/sni"
DOVE=/etc/dovecot/conf.d/98-fresk-ssl.conf
mkdir -p "$PF_DIR"

TMP_SNI="$(mktemp)"; TMP_DOVE="$(mktemp)"
{
  echo "# Generado por Flesk (flesk mail certs) — no editar"
  echo "ssl_server_cert_file = $DEF_CERT"
  echo "ssl_server_key_file = $DEF_KEY"
} > "$TMP_DOVE"
echo "# Generado por Flesk (flesk mail certs): <nombre> <clave> <cadena>" > "$TMP_SNI"
N=0
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  c="$LE/$d/fullchain.pem"; k="$LE/$d/privkey.pem"
  [[ -f "$c" && -f "$k" ]] || continue
  for h in mail smtp imap pop; do
    if cert_covers "$c" "$h.$d"; then
      printf '%s %s %s\n' "$h.$d" "$k" "$c" >> "$TMP_SNI"
      printf 'local_name %s {\n  ssl_server_cert_file = %s\n  ssl_server_key_file = %s\n}\n' "$h.$d" "$c" "$k" >> "$TMP_DOVE"
      N=$((N + 1))
    fi
  done
done < <(mysql_q -e "SELECT name FROM domains WHERE status='active' ORDER BY name;")

# --- Postfix ---
PF_BAK="$FRESK_RUN/main.cf.bak.$$"; cp -a /etc/postfix/main.cf "$PF_BAK"
[[ -f "$SNI" ]] && cp -a "$SNI" "$SNI.bak.$$"
install -m 640 -o root -g root "$TMP_SNI" "$SNI"
postmap -F "hash:$SNI"
chmod 640 "$SNI.db" 2>/dev/null || true
postconf -X smtpd_tls_cert_file smtpd_tls_key_file 2>/dev/null || true
postconf -e "smtpd_tls_chain_files = $DEF_KEY, $DEF_CERT" "tls_server_sni_maps = hash:$SNI" "smtpd_tls_security_level = may"
# Nombre del servidor de correo (HELO): PANEL_DOMAIN si el actual no es un FQDN
CUR_HN="$(postconf -h myhostname)"
if [[ "$CUR_HN" != *.* && -n "${PANEL_DOMAIN:-}" ]]; then postconf -e "myhostname = $PANEL_DOMAIN"; fi
if ! postfix check 2>/tmp/fresk-postfix-check.err; then
  cat /tmp/fresk-postfix-check.err >&2 || true
  cp -a "$PF_BAK" /etc/postfix/main.cf
  [[ -f "$SNI.bak.$$" ]] && cp -a "$SNI.bak.$$" "$SNI" && postmap -F "hash:$SNI"
  rm -f "$PF_BAK" "$SNI.bak.$$" "$TMP_SNI" "$TMP_DOVE"
  die 5 "postfix check falló; configuración restaurada"
fi
rm -f "$PF_BAK" "$SNI.bak.$$" "$TMP_SNI"
systemctl reload postfix

# --- Dovecot ---
DV_BAK=""
[[ -f "$DOVE" ]] && { DV_BAK="$FRESK_RUN/dove.bak.$$"; cp -a "$DOVE" "$DV_BAK"; }
install -m 644 -o root -g root "$TMP_DOVE" "$DOVE"; rm -f "$TMP_DOVE"
if ! doveconf -n >/dev/null 2>/tmp/fresk-doveconf.err; then
  cat /tmp/fresk-doveconf.err >&2 || true
  if [[ -n "$DV_BAK" ]]; then cp -a "$DV_BAK" "$DOVE"; else rm -f "$DOVE"; fi
  rm -f "$DV_BAK"
  die 5 "doveconf falló; configuración de Dovecot restaurada"
fi
rm -f "$DV_BAK"
systemctl reload dovecot

audit "cli" "mail.certs" "-" "ok" "default=$DEF_CERT sni=$N"
echo "OK mail certs default=$DEF_CERT sni=$N"
