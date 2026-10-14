#!/usr/bin/env bash
# Flesk — configura OpenDKIM (milter de Postfix), Roundcube (BD propia, pool PHP-FPM aislado,
# snippet nginx) y certificados de correo. Idempotente; lo ejecuta install.sh.
#   flesk mail setup
set -euo pipefail
FRESK_ROOT="${FRESK_ROOT:-/opt/flesk}"
# shellcheck disable=SC1091
source "$FRESK_ROOT/lib/common.sh"

require_root
ensure_installed
PHPV="${PHP_VERSION:-8.3}"
RC_SOCK="/run/php/php${PHPV}-fpm-roundcube.sock"

# ---------------------------------------------------------------- OpenDKIM
if command -v opendkim >/dev/null 2>&1; then
  install -d -m 755 -o root -g root /etc/opendkim
  install -d -m 750 -o opendkim -g opendkim /etc/opendkim/keys
  [[ -f /etc/opendkim/KeyTable ]] || install -m 644 /dev/null /etc/opendkim/KeyTable
  [[ -f /etc/opendkim/SigningTable ]] || install -m 644 /dev/null /etc/opendkim/SigningTable
  printf '127.0.0.1\n::1\nlocalhost\n' > /etc/opendkim/TrustedHosts
  if [[ -f /etc/opendkim.conf ]] && ! grep -q 'Flesk' /etc/opendkim.conf; then
    cp -a /etc/opendkim.conf "$FRESK_BACKUPS/opendkim.conf.orig" 2>/dev/null || true
  fi
  cat > /etc/opendkim.conf <<'DKIMCONF'
# OpenDKIM — generado por Flesk (flesk mail setup)
Syslog                  yes
UMask                   007
UserID                  opendkim
Mode                    sv
Canonicalization        relaxed/simple
SubDomains              no
OversignHeaders         From
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
TrustAnchorFile         /usr/share/dns/root.key
DKIMCONF
  [[ -f /usr/share/dns/root.key ]] || sed -i '/^TrustAnchorFile/d' /etc/opendkim.conf
  # Claves para los dominios existentes
  while IFS= read -r d; do
    [[ -n "$d" ]] && bash "$FRESK_ROOT/scripts/dkim.sh" ensure "$d" </dev/null >/dev/null || true
  done < <(mysql_q -e "SELECT name FROM domains WHERE status='active' ORDER BY name;")
  bash "$FRESK_ROOT/scripts/dkim.sh" sync >/dev/null
  systemctl enable opendkim >/dev/null 2>&1 || true
  systemctl restart opendkim
  postconf -e "smtpd_milters = inet:localhost:8891" "non_smtpd_milters = \$smtpd_milters" \
    "milter_default_action = accept" "milter_protocol = 6"
  postfix check && systemctl reload postfix
  log "INFO" "mail setup: OpenDKIM activo (inet:localhost:8891)"
else
  log "WARN" "mail setup: opendkim no instalado; se omite DKIM"
fi

# ---------------------------------------------------------------- Roundcube
# Release oficial (el paquete 1.6 de la distribución no funciona con PHP 8.5: array_first()).
# Versión fijada; SHA256 comprobado contra roundcube.net/download y la firma GPG
# de "Roundcube Developers" (F3E4 C04B B3DB 5D42 15C4 5F7F 5AB2 BAA1 41C4 F7D5).
RC_VER="${RC_VER:-1.7.4}"
RC_SHA256="${RC_SHA256:-2c6c878f0093f1bf7fb6086781d2dd9269d652c016b86939c157c5f1729139a2}"
RC_URL="https://github.com/roundcube/roundcubemail/releases/download/${RC_VER}/roundcubemail-${RC_VER}-complete.tar.gz"
RC_DIR="/opt/roundcube-${RC_VER}"
RC_LINK=/opt/roundcube
RC_ETC=/etc/flesk-roundcube
id roundcube >/dev/null 2>&1 || useradd --system --home "$RC_LINK" --shell /usr/sbin/nologin roundcube
if [[ ! -f "$RC_DIR/index.php" ]]; then
  T="$(mktemp -d)"
  curl -fsSL --max-time 300 -o "$T/rc.tgz" "$RC_URL" || die 5 "No se pudo descargar Roundcube $RC_VER"
  echo "${RC_SHA256}  $T/rc.tgz" | sha256sum -c --quiet - || { rm -rf "$T"; die 5 "SHA256 de Roundcube no coincide"; }
  tar -xzf "$T/rc.tgz" -C "$T"
  rm -rf "$RC_DIR"; mv "$T/roundcubemail-${RC_VER}" "$RC_DIR"; rm -rf "$T"
  rm -rf "$RC_DIR/installer"
  chown -R root:root "$RC_DIR"
  log "INFO" "mail setup: Roundcube $RC_VER instalado en $RC_DIR"
fi
ln -sfn "$RC_DIR" "$RC_LINK"
install -d -m 750 -o roundcube -g roundcube "$RC_DIR/temp" "$RC_DIR/logs"
install -d -m 750 -o root -g roundcube "$RC_ETC"
# BD propia (usuario local con contraseña aleatoria), secretos fuera del árbol de Roundcube
if [[ ! -f "$RC_ETC/secrets.inc.php" ]]; then
  RCPASS="$(gen_password)"; DESKEY="$(gen_password)"
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY '${RCPASS}';
ALTER USER 'roundcube'@'localhost' IDENTIFIED BY '${RCPASS}';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
SQL
  ( umask 027
    printf "<?php\n// Generado por Flesk — secretos de Roundcube\n\$config['db_dsnw'] = 'mysql://roundcube:%s@localhost/roundcube';\n\$config['des_key'] = '%s';\n" "$RCPASS" "$DESKEY" > "$RC_ETC/secrets.inc.php" )
  unset RCPASS DESKEY
fi
cat > "$RC_ETC/config.inc.php" <<'RCPHP'
<?php
// Generado por Flesk (flesk mail setup)
$config = [];
include '/etc/flesk-roundcube/secrets.inc.php';
$config['imap_host'] = 'localhost:143';
$config['smtp_host'] = 'tls://localhost:587';
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
$config['username_domain'] = '%t';
$config['mail_domain'] = '%t';
$config['product_name'] = 'Webmail';
$config['support_url'] = '';
$config['plugins'] = ['archive', 'zipdownload', 'markasjunk'];
$config['enable_installer'] = false;
$config['ip_check'] = false;
$config['session_lifetime'] = 30;
$config['language'] = 'es_ES';
$config['skin'] = 'elastic';
$config['log_driver'] = 'file';
$config['temp_dir'] = '/opt/roundcube/temp/';
$config['log_dir'] = '/opt/roundcube/logs/';
RCPHP
chown root:roundcube "$RC_ETC"/*.inc.php; chmod 640 "$RC_ETC"/*.inc.php
ln -sfn "$RC_ETC/config.inc.php" "$RC_DIR/config/config.inc.php"
if [[ "$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='roundcube';")" == "0" ]]; then
  mysql -u root roundcube < "$RC_DIR/SQL/mysql.initial.sql"
  log "INFO" "mail setup: esquema de Roundcube cargado"
else
  runuser -u roundcube -- php "$RC_DIR/bin/updatedb.sh" --package=roundcube --dir="$RC_DIR/SQL" >/dev/null 2>&1 || log "WARN" "updatedb de Roundcube falló"
fi
# Pool PHP-FPM aislado (usuario roundcube, sin acceso al panel)
cat > "/etc/php/${PHPV}/fpm/pool.d/roundcube.conf" <<POOL
; Roundcube — generado por Flesk
[roundcube]
user = roundcube
group = roundcube
listen = ${RC_SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
php_admin_value[open_basedir] = /opt/roundcube:${RC_DIR}:${RC_ETC}:/tmp
php_admin_value[upload_max_filesize] = 25M
php_admin_value[post_max_size] = 30M
php_admin_value[memory_limit] = 128M
php_admin_flag[expose_php] = off
php_admin_value[error_log] = ${RC_DIR}/logs/php-error.log
POOL
"php-fpm${PHPV}" -t >/dev/null 2>&1 || die 5 "php-fpm -t falló tras escribir el pool roundcube"
systemctl reload "php${PHPV}-fpm"
render_template "$FRESK_ROOT/templates/nginx-roundcube.conf" /etc/nginx/snippets/flesk-roundcube.conf "RC_SOCK=$RC_SOCK"
chmod 644 /etc/nginx/snippets/flesk-roundcube.conf
# vhost webmail.<dominio> para cada dominio
while IFS= read -r d; do
  [[ -n "$d" ]] && bash "$FRESK_ROOT/scripts/webmail-vhost.sh" vhost "$d" </dev/null >/dev/null || true
done < <(mysql_q -e "SELECT name FROM domains WHERE status='active' ORDER BY name;")
log "INFO" "mail setup: Roundcube $RC_VER listo (webmail.<dominio>)"

# ---------------------------------------------------------------- Certificados de correo + hook de renovación
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/flesk-mail.sh <<HOOK
#!/bin/sh
# Flesk: tras renovar, reaplica certificados de Postfix/Dovecot y el vhost webmail
for d in \$RENEWED_DOMAINS; do
  case "\$d" in \*.*) continue ;; esac
  d="\${d#webmail.}"
  [ -f "${NGINX_ENABLED:-/etc/nginx/fresk-enabled}/\$d.webmail.conf" ] && ${FRESK_ROOT}/bin/flesk webmail vhost "\$d" >/dev/null 2>&1 || true
done
${FRESK_ROOT}/bin/flesk mail certs >/dev/null 2>&1 || true
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/flesk-mail.sh
bash "$FRESK_ROOT/scripts/mail-certs.sh"

audit "cli" "mail.setup" "-" "ok" "opendkim+roundcube+certs"
echo "OK mail setup"
